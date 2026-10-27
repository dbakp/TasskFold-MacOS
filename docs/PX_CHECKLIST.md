# Px checklist — 27 October 2026

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
- [ ] Remaining external file-provider transfer and recovery acceptance.

### 2. Share and browser capture

- [x] Native share extensions, bounded reviewed text/link intake and account-bound
  saved drafts, with representative offline/relaunch/isolation checks.
- [ ] Remaining Mac share-menu, spoken accessibility and wider source-app cases.

### 3. Notes, output and view control — active

- [x] Note formatting and readable plain-text fallback implementation.
- [x] Gated imported-heading review for root tasks: exact captured-draft checks, local Mac
  Cancel/autosave/Undo/Redo/child-completion/cold return, and phone/tablet reviewed
  Save/cold return with long edited wording at dark largest text. Mac runtime
  warnings and broader shared/cloud/spoken acceptance remain open.
- [x] Native print/PDF implementation and representative output verification.
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
- [ ] Independent child-task database migration and audio comments.
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
