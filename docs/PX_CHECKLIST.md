# Px checklist — 29 October 2026

This is a feature-level progress snapshot, not a release-readiness certificate.
Checked items are complete within their recorded acceptance scope. Open items
include implementation, exposure or verification; source-only work is not marked
as generally available. See P1_PLAN.md, p1-completion-audit.json and P2_PLAN.md for
exact evidence. Each repository owns its app, widgets, tests and release inputs.

## Foundation and P0 follow-ups

- [x] Project archive/restore and owner-safe subprojects.
- [x] Reusable workflows and reviewed multi-line capture.
- [x] Local notification actions, task completion and Undo in recorded native flows.
- [x] Widget routing, completion feedback and representative account/privacy checks,
  including the physical iPhone Today Lock Screen background/privacy repair.
- [x] Backup/restore and critical VoiceOver journeys in recorded native scopes.
- [x] Deployed account-removal service and genuine iPhone deletion/retry proof.
- [ ] Remaining account-removal recovery variants and Mac private-Keychain/runtime
  verification. Newer protocol recovery proof does not accept every older attempt.

## P1 — agreed implementation and acceptance batch

- [x] Nested subtask editing, notes/planning, branch organization and saved-state
  preservation, including recorded concurrent move/edit checks.
- [x] Saved template definition editing and reviewed source replacement; existing
  runs remain independent.
- [x] Widget supported manual/grouped order, remaining order after completion and
  installed Mac completion/relaunch proof.
- [x] Insights, daily/weekly goals, rest days, completion deduplication and reopen
  corrections within recorded history coverage.
- [x] Multiple monthly recurrence dates, preview, persistence, completion and Undo.
- [x] Read-only Google/Outlook connection implementation and synthetic/native
  settings/timeline acceptance.
- [ ] Genuine Google/Microsoft registration, consent, refresh/revocation and
  provider-backed credential acceptance — explicitly deferred by the user.
- [x] Current-project activity and permission-checked explicit mentions within
  recorded native and genuine HTTP/server scopes.

## P2 — ranked remaining product backlog

### 1. Portable templates

- [x] Versioned workflow files, reviewed import/export, private copies and malformed/
  incompatible-file refusal; opening a definition does not create tasks.
- [x] Cancellation now reaches the template file reader; bounded reads and useful
  unavailable-file recovery pass controlled provider checks in each app.
- [x] Native Mac/phone/tablet picker wait, Cancel, late-response suppression,
  retry and unchanged cold-return scope using a separate-process file presenter.
  Mac runtime warning remains open; this is not real cloud-provider transfer.
- [ ] Remaining external file-provider transfer and recovery acceptance.

### 2. Share and browser capture

- [x] Native share extensions, bounded reviewed text/link intake and account-bound
  saved drafts, with representative offline/relaunch/isolation checks.
- [x] Native Mac Safari and TextEdit intake, local host review/Cancel/Add,
  Undo/Redo and cold-return scope; temporary extension setting restored Off.
- [ ] Remaining Mac cloud/account/spoken accessibility and wider source-app cases.

### 3. Notes, output and view control — active

- [x] Note formatting and readable plain-text fallback implementation.
- [x] Gated imported-heading review for root tasks: exact captured-draft checks, local Mac
  Cancel/autosave/Undo/Redo/child-completion/cold return, and phone/tablet reviewed
  Save/cold return with long edited wording at dark largest text. Mac runtime
  warnings and broader shared/cloud/spoken acceptance remain open.
- [x] Native print/PDF implementation and representative output verification.
- [x] Pinned-note mobile largest-text Save/readback, Cancel/cold return and changed-
  source refusal; Mac CUA Save/Cancel/readback. Exact limits: pinned-note-output/.
- [x] Native mobile CSV Share-to-local-Files, actual readback/cold preservation
  and four-row dark largest-text review; see task-csv-share-files/. Mac/provider/
  spoken and wider output scopes remain open.
- [x] Expanded saved filters, grouping and gesture controls in recorded scopes.
- [x] Heading contracts and guarded native editors; ordinary authoring remains gated.
- [x] Child-work integration with lists, planning, calendars, widgets and progress
  in the implemented adapters.
- [x] Workflow creation, Undo and background widget-publication improvements with
  recorded cancellation, privacy, stale-worker and save-failure checks.
- [ ] Finish remaining heading/child-data adapters, hosted compatibility/exposure
  and cross-device acceptance. Source migrations are not deployed merely because
  their files exist. Rollout dependencies remain deferred.
- [ ] Remaining native/spoken/largest-text, file-provider and cross-device cases.
- [ ] Mac runtime warning gate: observed Services-menu/data-detector accessibility
  stacks remain recorded; functional passes do not establish clean runtime.
- [ ] Further reduce synchronous large-workflow save pauses; validate production
  rendering, richer child/assignment workloads and hosted/paired bulk delivery.
  Latest scoped change skips discarded normalization setup for exactly admitted
  fresh local commands. Three Debug observations per version put the 5,000-task
  median commit at about 0.17 seconds (previously 0.22). See
  workflow-normalization-setup/README.md;
  the broader item remains open.
- [x] Background local-history preparation, changed-source fallback and recorded
  Core/native functional verification. Mac warnings and remaining pauses stay
  open. See local-history-worker/ for scoped results.

### 4. Reviewed voice drafts

- [x] Device-transcription draft/review, correction and explicit Apply implementation.
- [x] Exact parent-draft UTF-8 binding, Mac native correction/Cancel/Apply/Add/Undo/Redo
  and cold return with synthetic recording/refusal; final phone/tablet review and
  roomy iPad largest-text presentation. See voice-draft-native/ for scoped evidence.
- [ ] Genuine microphone/permission/audio/cancellation and Mac speech acceptance.
- [ ] Cloud AI assistance: provider, cost and data handling undecided; disabled.

### 5. Advanced reminders and recurrence

- [x] Interval, time-zone, reviewed country-holiday policy and location foundations.
- [x] Private place storage, native setup, snooze/cancellation and recovery flows
  with recorded Simulator/Core acceptance.
- [ ] Physical geofence delivery — deferred until the user is available.
- [ ] Remaining travel and Time Sensitive delivery verification; no critical/urgent
  delivery guarantee is claimed from ordinary local notifications.
- [ ] Assigned-recipient/server reminders remain with deferred remote delivery.

### 6. Automation and advanced teams

- [x] Scoped/revocable API credentials, webhook delivery/recovery and email-intake
  foundations with recorded local/hosted/native scopes.
- [x] Team organization, roles/folders and guarded task-operation implementations,
  including reviewed templates, selections and saved recovery drafts.
- [x] Representative server/mobile permission and recovery acceptance.
- [ ] Broader role/recovery/Mac/spoken checks and production exposure of gated
  candidates. New client UI alone does not establish server role enforcement.
- [ ] Independent child-task database migration.
- [x] Private opt-in child records: exact adoption, lossless fields/order/shapes,
  stable current identity and fresh incarnations after removal/recreation, atomic
  legacy-write synchronization and review instead of guessed identities.
- [x] Disabled authenticated child-record server read contract, live sessions and
  current personal/team read admission, source/record integrity and bounded data.
  Both repos pass 43 database checks; see [read evidence](child-task-record-reads/README.md).
- [x] Client read data layer: bounded strict decoding, exact reconstruction,
  context-bound Backend and gated Store method. 93 Core/transport checks per repo,
  43 database checks and both app builds. [Evidence](child-task-record-client/README.md).
- [x] Disabled server non-completion child field commands: field-change fences,
  current permissions, guarded legacy bridging, atomic receipts and retry proof.
  95 database and 94 selected Core/transport checks per repo. [Evidence](child-task-field-edits/README.md).
- [ ] Native command journals/receipts, Store/editor adoption and lifecycle;
  completion/structural child commands, certified Undo, offline/UI and rollout. See [child record stage](child-task-records/README.md).
- [ ] Audio comments remain gated. Implemented: private recording/recovery/library
  and portable backups; durable publication/retry; authenticated paged live metadata,
  native verified download/play and explicit removal in a personal-root preview.
  Shared/archived project reads now have separate admission and denied-access clearing.
  Latest sender recovery checks: 203 Core, 282 controller, 31 gateway, 51 database/
  gateway, 37 native owner, 54 terminal and 24 publication regression checks per repo. Prior shared-read
  and mixed timeline evidence remain separately recorded. Exact expired/retired
  operations now retain a closed proof and private media without resending.
  Pending: team audio writing/custody, full native Store/shared-account lifecycle,
  remaining UI/spoken acceptance, legacy-history, hosted
  custody/provider and genuine audio acceptance. See [timeline evidence](conversation-timeline/README.md),
  [shared-read evidence](audio-shared-read/README.md)
  and [AUDIO_COMMENTS.md](AUDIO_COMMENTS.md).
- [ ] Inbound email provider/domain configuration and genuine delivery — prepare
  only until the user supplies configuration.

### 7. Wearables

- [x] Apple Watch Today, reviewed capture and durable offline-completion implementation.
- [x] Recorded paired Watch/iPhone Simulator acceptance.
- [ ] Hardware, background delivery, account/reinstall and spoken accessibility.
- [ ] Wear OS/Android: future independently owned clients, not Apple-repo code.

## Explicit deferrals — do not reopen without user direction

- [ ] Server-delivered reminders and device/reinstall delivery recovery.
- [ ] Older-client editing/upgrade/rollout safeguards.
- [ ] Release signing, real installation/update checks and Mac distribution.
- [ ] Genuine Google/Microsoft OAuth registration and provider acceptance.
- [ ] Physical geofence delivery, until the user is available.
- [ ] Inbound email provider/domain configuration; prepare for later setup.

The whole Px objective remains active. This checklist deliberately has no overall
percentage: these packages differ greatly in size, and implemented source is not
equivalent to a feature being ready to expose or release.

## 2026-10-27 — prepared local workflow Undo

- [x] Move bounded Undo construction for eligible fresh local workflows into the
  existing background preparation; keep final validation, durable save and fallback.
- [x] Verify 96 distinct focused Core cases per repo and selected native local
  creation, cancellation, failed-save, source-change and 5,000-task publication.
- [ ] Remove the remaining synchronous encoding/save pause; broader performance
  work is still open.
- [ ] Resolve intermittent mobile cloud-workflow settle timeouts and Mac runtime
  warnings. Passing diagnostic retries do not explain earlier failures.

Evidence and exact scope: [prepared workflow Undo](prepared-workflow-undo/README.md).

## 2026-10-27 — background local workflow encoding

- [x] Prepare the ordinary snapshot encoding in the worker; reuse only unchanged
  table buffers and raw metadata after final validation and receipt staging.
- [x] Keep atomic durable save, final widget-token validation, cancellation,
  failed-save preservation, changed-source fallback and Undo behavior.
- [x] Verify 104 distinct focused Core cases per repo, warning-free six-case
  phone/tablet results and the recorded split Mac functional scope.
- [ ] Reduce the remaining roughly 0.6-second synchronous 5,000-root commit and
  validate richer workloads and production rendering.
- [ ] Close Mac runtime/geometry warnings and explain earlier intermittent mobile
  cloud-settle timeouts. Current passes alone do not establish those causes.

[Measurements, source bindings and exact acceptance scope](workflow-cache-encoding/README.md).


## 2026-10-27 — audio draft review candidate

- [x] Native recorder/player sources, exclusive lease shared with dictation,
  two-minute presentation-duration validation and private review/save/restore.
- [x] 47 focused Core, 19 synthetic audio-controller and 17 dictation-controller
  checks per repo; four distinct native screen cases each on Mac/phone/iPad,
  with the iPhone replacement case accepted in a targeted rerun. No reported
  runtime warnings in those accepted scopes. See audio-comment-media/.
- [ ] Complete ordinary app entry points, private cloud publication/access/custody,
  full save-conflict/account/window/Quit/background/backup lifecycle and genuine
  recording/playback/spoken acceptance before exposing audio comments.
- [ ] Genuine microphone/speaker testing stays deferred per the user's request.


## 2026-10-27 — interrupted audio-review recovery checkpoint

- [x] Separate account-private recovery copies for validated unsaved recordings and
  exact captions, including coalesced edits and frozen uncertain-write retries.
- [x] Original-owner completion after context loss, bounded failed-write retention,
  exact-owner/task retry, explicit Retry UI and native review of recovered media.
- [x] Explicit Save/Discard settlement and separate-copy resolution of conflicting
  saved drafts; dirty deletion refused in the controller as well as the UI.
- [x] 55 focused Core and 42 synthetic controller checks per independently owned repo.
- [x] Six current native cases each on Mac, iPhone and iPad, with no reported
  runtime warnings, including interrupted-review recovery and explicit discard.
- [ ] Complete normal-Quit/background/raw-recording, account-removal, storage-full/
  cleanup and private server lifecycle before ordinary exposure. Genuine audio
  acceptance remains user-deferred. See audio-comment-recovery/ for native evidence.


## 2026-10-27 — finish interrupted local audio Saves

- [x] Durable exact Save identity before primary replacement; original-ID resume
  across fresh presentations and separate-copy journal replacement.
- [x] Saves to finish UI, protected recovery rows, full decode before resume,
  idempotent late Finish, refusal to resurrect a deliberately deleted recording.
- [x] Immutable storage-owner binding; a failing-before/passing-after synthetic
  wrong-store summary-isolation check; original-owner in-flight Save completion.
- [x] 66 focused Core / 54 actual-controller checks per repo, plus four current
  native cases each on Mac/iPhone/iPad with no reported runtime warnings; largest
  mobile text is covered. See audio-comment-save/; hardware/speech is not implied.
- [x] Concurrent-editor recovery claiming and prepared-Save cancellation/quota
  completed in the following checkpoint.
- [ ] Orphan/corrupt-file recovery, full account/Quit/background/backup lifecycle,
  ordinary app integration and private server audio delivery. Feature stays gated.


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


## 2026-10-27 — reviewed PDF/CSV byte release and exact source refresh

- [x] Live source, workspace incarnation, selected options and presentation checks
  at PDF/CSV byte release, including CSV Share. Separate Save identities reject
  stale callbacks; closing or cancelling permanently revokes old permits.
- [x] Exact UTF-8 source comparison and task-cache refresh for canonically equivalent
  edits. Two failing-before regressions reproduce the original comparison/cache bugs;
  unchanged rows retain cached results. Pinned-note checks use the whole record.
- [x] Actual local PDF/CSV Save/readback and cancellation, source/incarnation changes
  while Save is open, unchanged saved tables and cold return: four native Mac cases
  and five each on iPhone/iPad Simulator, no failures/skips/reported runtime warnings.
- [x] Fourteen new Core cases per repo. Focused totals: Mac 105 passed plus two
  existing fixture-dependent skips; iOS 106 passed. Full saved CSV bytes agree on all
  three platforms; PDF readback preserves multiple pages and final instructions.
- [ ] Real authenticated account-picker/multi-window races, external cloud-provider
  delivery, native pinned-note source changes, spoken/largest-text output acceptance
  and hardware printing remain open. Already-released provider copies cannot be recalled.

Evidence: [task-output-release](task-output-release/README.md). This closes a scoped
rank-3 output-safety checkpoint, not the full Px goal. Real audio tests remain
user-deferred; no microphone/speech permissions or speaker test was requested.


## 2026-10-28 — pinned-note native PDF acceptance

- [x] Two selected native cases each on iPhone/iPad Simulator: dark largest-text
  note PDF Save/readback, repeat Save/Cancel, unchanged saved tables/cold return,
  and raw source revocation while the native Save picker is open. No reported
  XCTest runtime warnings; all six retained mobile captures inspected.
- [x] Mac CUA local pinned-note Save and repeat Cancel; actual two-page PDF readback.
  This is a manual native scope, not a passing Mac XCTest/runtime suite.
- [ ] Mac automated pinned-note source-change/cold-return preservation remains open:
  the runner twice failed to enable automation before launching the app.
- [ ] Other output largest-text/spoken/provider/account-picker/multi-window and
  hardware-print gates remain open. See [pinned-note-output](pinned-note-output/README.md).

Largest-text entry failures were test navigation mistakes: the lazy note row was
below the library viewport. The driver now uses normal scrolling. No speculative
tap-target/layout fix or temporary callback instrumentation remains in app code.


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

## 2026-10-28 — adopt prepared local workflow rows

- [x] Avoid the second row append pass after full immutable projection admission; preserve final Store validation.
- [x] Replay ordinary creation after late rejection, including empty/project-only workflows.
- [x] 108 selected Core cases per repo; seven warning-free native cases each on phone/tablet; clean Mac Create/Undo/Redo.
- [ ] Reduce the remaining ~0.49-second synchronous 5,000-root Mac commit; verify richer workloads and production rendering.
- [ ] Close previously recorded Mac runtime and cloud-settle gates.

[Evidence, measurements and exact limits](workflow-projection-adoption/README.md).

## 2026-10-28 — destination-only workflow identity indexes

- [x] Stop scanning unrelated saved history/recovery/future rows for workflow insertion collisions.
- [x] Compare 123 admission decisions with the frozen legacy constructor and preserve admitted rows and consumed-command refusal.
- [x] 97 selected Core cases pass before and after in each repo; both native builds and signatures pass.
- [ ] End-to-end save/rendering and richer child/assignment workloads remain open; component timings do not close those gates.

[Evidence and precise scope](workflow-destination-index/README.md).

## 2026-10-28 — exact filtered-task output admission

- [x] Reproduce stale root/child source acceptance hidden by Swift canonical equality, then refuse it using the existing exact authored-source comparison.
- [x] Preserve refreshed PDF/CSV output and object insertion-order tolerance; selected Core suites pass 104 Mac / 105 iOS cases.
- [x] Build and verify signatures for both current native apps.
- [ ] Wider spoken, cross-device and external file-provider acceptance remains open.

[Evidence and native acceptance scope](filtered-output-source/README.md).

Native output follow-up: iPad passes all three selected journeys; iPhone passes CSV/cold-return and source revocation, but repeat PDF Save reliability remains open. Same-name replacement and an unshipped filename-field driver attempt are retained as separate failures in filtered-output-source/. No experimental driver change ships.

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

## 2026-10-28 — skip redundant workflow Undo identity scans

- [x] Avoid reading/indexing the baseline when an Undo inverse is already available; otherwise index only checked destination tables.
- [x] Preserve the original refusal decisions, including missing inverses, existing-row replays, Unicode/case identities and mixed/non-workflow commands: 3,240 legacy comparisons and 102 selected Core tests per repo.
- [x] The unchanged test corpus fails its baseline-access assertion before optimization and passes afterward. A 90,000-row Debug guard diagnostic records the eliminated scan; no full-save speedup is inferred.
- [x] Four native mobile passes: actual local Create/Undo on phone/tablet, plus phone 5,000-task publication and failed-save preservation; both app builds/signatures pass.
- [ ] The native phone observation still has a ~0.47-second synchronous commit. Full save latency, production rendering, richer child/assignment workloads, hosted/paired delivery and Mac runtime/geometry remain open.

[Evidence, timings and exact scope](workflow-history-guard/README.md). All user deferrals and the wider Px goal remain unchanged.


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


## 2026-10-28 — disabled authenticated audio gateway candidate

- [x] Implement fixed-origin Auth/live-session verification, service-only admission
  and shared request budgets, constrained private bucket/client denial, bounded
  upload with full stored-byte/hash readback, original-ID retry/no overwrite,
  authenticated download with a post-read authority check, listing and retirement.
- [x] Independently pass 18 Deno tests and 54 real PostgreSQL/boundary/loopback HTTP
  checks per repo; no introduced official CLI advisor findings. HTTP uses the
  production handler, real SQL and controlled local Auth/Storage adapters.
- [ ] Late-upload-safe physical cleanup, native publication journal/comment UI,
  real Supabase Auth/Storage acceptance and remaining genuine/native audio
  acceptance. No deployment or normal audio exposure; all gates stay off.

[Evidence, reproducible commands and limits](audio-comment-gateway/README.md).
This is a verified disabled delivery candidate, not completion of audio or Px.


## 2026-10-28 — durable upload fence and cleanup worker candidate

- [x] Fence each upload with a durable single open ticket. Timeouts never release
  quota; verified finalization reconciles lost ACKs. Retired recordings cannot
  start new uploads, and unresolved uploads are excluded from cleanup.
- [x] Add service-only rotating cleanup claims and a separately authenticated,
  default-off maintenance worker. Remove through Storage HTTP, verify absence,
  then confirm against the live claim and SQL metadata; failed removal retains quota.
- [x] Independently pass 26 Deno tests and 82 real PostgreSQL/boundary/loopback HTTP
  checks per repo with no new CLI advisor findings. All fixtures are synthetic.
- [ ] Process-loss/retirement reconciliation of uncertain uploads, scheduled worker
  acceptance and full custody/removal cases, real provider/backing-store acceptance,
  native publication/comment UI and remaining genuine/native audio acceptance.
  Open tickets currently retain quota indefinitely; this is not the final UX.

[Evidence and exact limits](audio-comment-cleanup/README.md). No deployment or
normal audio exposure; the broader audio/Px requirements remain open.


## 2026-10-28 — retired-file recovery and signed maintenance schedule

- [x] Recover a retired unknown upload only after complete stored-byte size/hash
  verification and current SQL ticket/object checks. Concurrent probes use bounded
  claims/backoff; absent/corrupt files retain their fence and quota.
- [x] Add an inactive minute cron candidate with private Vault lookup, project-bound
  short-lived HMAC and one-use SQL admission. No reusable key enters the HTTP queue.
  The maintenance function uses its own authenticated schedule path; its deployment
  flag and the separate user gateway JWT requirement are explicit in the runbook.
- [x] Independently pass 33 handler tests, 93 real PostgreSQL/boundary/HTTP checks and
  33 real pg_cron/signed HTTP checks per repo; no new official advisor findings.
  The real cron proof drives recovery, fixture-byte deletion and quota release.
- [ ] Terminal evidence/recovery for unknown absent/corrupt uploads, genuine hosted
  Vault/pg_net/Edge/Storage/deletion acceptance and full custody/removal cases,
  native publication/comment UI and remaining genuine/native audio acceptance.

[Evidence, limits and operator preparation](audio-maintenance-recovery/README.md).
No hosted deployment/configuration; all normal audio flags and the cron job stay off.
The audio feature and full Px objective remain open.


## 2026-10-28 — native publication journal and authenticated transport

- [x] Persist a server/account/recording-revision-bound frozen operation before
  publication; reuse it across controllers/processes, prevent competing identities
  and atomically retain a strict published receipt without duplicate audio.
- [x] Add observable target/session-bound publication/retry flow and actual Backend
  native-decode/fixed-route transport with bounded responses, stable JSON/base64,
  account/departure checks and sanitized uncertain outcomes. Normal UI stays gated.
- [x] Independently pass 161 audio Core tests, 20 real process recovery checks and
  14 native-to-Deno/real-PostgreSQL checks per repo. Lost native reply, restart retry
  and confirmed restart preserve one operation; the final restart sends no HTTP.
- [ ] Store/native control wiring, live comment listing/download/removal/rendering,
  native runtime/accessibility and local journal management, real provider acceptance
  and remaining unknown-upload recovery. No full app/mobile UI acceptance is claimed.

[Evidence and next required work](audio-native-publication/README.md). This is the
verified client foundation; normal audio and the overall Px goal remain open.


## 2026-10-28 — gated saved-recording publication controls

- [x] Connect saved recording review to separate publishing admission and the
  durable native flow. Bind library selection, server/account/workspace/task and
  session; revalidate saved bytes/revision and preserve legacy pending operations.
- [x] Add explicit Review/Publish, Check publication, preparation/sending progress,
  historical confirmation, sign-in/error feedback and local-status Reload. Opening
  review is local-only; context/scene departure invalidates late presentation.
- [x] Independently pass 164 Core audio tests and 235 actual recording-controller
  checks per repo. Complete unsigned app builds pass for Mac arm64 and iOS Simulator
  arm64/x86_64; normal recording/publishing Info flags are absent/off.
- [ ] Native runtime/visual/accessibility control acceptance, older/orphaned pending
  publication review/management, live audio conversation/read/play/remove and real
  provider acceptance. No app UI or release/signature acceptance is claimed.

[Evidence and limits](audio-publication-controls/README.md). Normal publishing
remains gated and the overall audio/Px requirements remain open.


## 2026-10-28 — private publication-copy recovery

- [x] Review pending/orphaned original recordings independently of edited drafts;
  keep idempotent private copies without overwriting edits or duplicating sends.
- [x] Retain confirmed audio until explicit local removal; preserve server comments,
  saved drafts and compact proof. Reject pending deletion and revoke stale playback.
- [x] Verify session-transition masking, pending metadata reservation and compaction
  with a full pending quota. Independently pass 170 Core, 253 controller and 20
  native/gateway/PostgreSQL checks per repo; unsigned full app builds pass.
- [ ] Native runtime/visual/accessibility, live audio conversations/read/play/remove,
  uncertain-upload terminal recovery, legacy journal/history policy and hosted
  provider acceptance. Genuine audio checks remain user-deferred; gates stay off.

[Evidence and limits](audio-pending-review/README.md). This closes the implemented
orphan-review/retention gap, with native acceptance and the overall Px goal open.


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
- [x] Sender status after task/access loss and explicit absent-operation closure now
  pass the follow-up API/database/native-process scope below.
- [ ] Native closed-state/full Store UI, legacy/history policy and hosted provider/
  custody acceptance.
  Genuine audio and existing user deferrals stay pending; ordinary flags stay off.

[Evidence, exact limits and reproduction](audio-publication-closed/README.md).
This closes the exact-reservation terminal gap; the full audio/Px feature stays open.

## 2026-10-28 — sender status and explicit original-send closure

- [x] Metadata-only original-send check after task deletion/access loss; no upload
  or current content/media read grant. Resume requires separate confirmation and
  existing current publishing admission.
- [x] Explicit original-send closure preserves private audio and blocks delayed
  reserve/finalize, including an absent server reservation. Published history wins
  over cancellation; unresolved upload leases remain fenced.
- [x] Each repo: 203 Core, 282 controller, 31 gateway, 51 database/gateway, 37 native
  owner-recovery, 54 terminal and 24 publication regression checks; unsigned builds.
- [ ] New native controls/layout/spoken/full Store lifecycle, legacy/history/cap
  policy, team custody and hosted provider acceptance. Ordinary flags stay off.

[Evidence and exact limits](audio-owner-status/README.md).

## 2026-10-28 — native original-send review

- [x] Shorten the unconfirmed result without implying the original send never
  uploaded. Scroll results into view before requesting VoiceOver focus.
- [x] Five distinct iPhone/iPad component journeys each across recorded phases:
  Check without upload, Close/Cancel, cold proof/media retention, separately
  confirmed private removal, published precedence, Resume/Cancel and failure.
- [x] Real system speech for asynchronous unconfirmed results; four inspected
  dark Accessibility XXXL images and both isolated app/test builds/signatures.
- [ ] Mac native review/layout/spoken acceptance, full Store/main publisher and
  shared-account/window lifecycle, other VoiceOver actions/result variants.
- [ ] Legacy/history/marker policy, team custody and real provider/genuine audio
  acceptance. Existing user deferrals remain; normal audio gates are off.

[Exact phases, failures, fixes and limits](audio-owner-review-native/README.md).

## 2026-10-29 — skip discarded local workflow setup

- [x] Use the existing exact worker admission before allocating normalization
  command copies/catalog indexes; ordinary and stale inputs retain the old path.
- [x] Reuse the prepared fresh-run shape without caching current permissions or
  changing row validation, receipt staging, durable save, rollback or Undo.
- [x] Three native Debug observations each before/after: 5,000-task median commit
  220 → 171 ms. Branch use and existing saved/history/widget invariants pass.
- [x] 118 focused Core cases in each repo; six native iPhone and two iPad
  functional cases, both isolated app/test builds and signatures.
- [ ] Remaining synchronous pause, richer workloads/production rendering, Mac
  runtime/warnings and genuine cloud/paired delivery. Px stays unfinished.

[Measurements, exact acceptance and limits](workflow-normalization-setup/README.md).
