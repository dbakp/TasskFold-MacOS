# Px checklist — 28 October 2026

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
- [ ] Audio comments: bounded clip/decode, scoped private storage and a native review
  candidate now have 79 Core and 62 synthetic audio-controller checks per repo,
  including concurrent recovered-review ownership, durable pending cancellation,
  private interrupted-review recovery and explicit conflict copies.
  The unchanged shared dictation lease passed 17 controller checks at the prior checkpoint. Ordinary app entry points, private server lifecycle and genuine
  microphone/speaker/accessibility acceptance remain open; see
  [AUDIO_COMMENTS.md](AUDIO_COMMENTS.md).
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
