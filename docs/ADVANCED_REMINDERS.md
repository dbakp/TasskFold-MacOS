# Advanced reminder delivery plan

This is rank 5 of P2_PLAN.md. It does not reopen server delivery or release verification. Ordinary local alerts remain subject to the device's permission, delivery settings and scheduling budget. The task's repeat rule and an independent reminder schedule remain separate concepts.

## Delivery order

1. **Elapsed repeating reminders.** Add an opt-in Interval choice beside From plan, Fixed time and Repeats. The user chooses the first instant and a whole-minute interval from 5 minutes through 7 days. Offer 15/30/60-minute presets plus a custom value. Show the next five actual dates/times with the current display zone before saving. Never infer an interval from free text that the user has not reviewed.
2. **Travel clarity.** Label interval reminders as elapsed time. Existing calendar reminders retain their saved source-zone clock; fixed reminders retain their instant. The editor now offers a named-zone chooser and compares up to five actual source/device clock times, including offset changes. See REMINDER_TIME_ZONES.md. A future follow-my-current-zone clock is a separate explicit choice, not a migration of existing schedules.
3. **Holiday policy.** Offer explicit Skip or Move policies only after a reviewed holiday source/region, source updates, date boundaries and count/end semantics are agreed. Do not infer holidays from a device locale, silently change task dates or couple a user's private calendar to shared reminders. Automatic country/year public calendars are the primary source, with reviewed finite snapshots and optional all-day calendar files. Independent reminder Skip/Move policies are implemented in `HOLIDAY_REMINDERS.md`. Silent multi-year subscriptions remain unfinished; provider commercial sponsorship and genuine delivery acceptance stay open.
4. **Location reminders.** Define arrival/departure, location precision, opt-in permissions, device ownership, background/reinstall recovery, data retention and unsupported-platform presentation before requesting location access. Cross-platform editing must preserve unsupported settings. The device-private one-shot and every-visit models, protected store, reviewed drafts, shared admission, cancellation and action handling are implemented in `LOCATION_REMINDERS.md`. iOS native codecs, unsupported-device refusals and isolated drafts/action flows are tested. Public setup/authoring, private desktop-to-phone authoring and positive capable-device region/background delivery remain unfinished. Optional one-use location access exists only after a picker tap; no background tracking is added.
5. **Urgent presentation.** Define the explicit user choice and available OS capability before adding elevated presentation. Never label ordinary alerts as critical, guaranteed or emergency delivery. Keep normal delivery available. Opt-in Time Sensitive presentation is now implemented separately, with normal fallback and no Critical Alerts; see REMINDER_PRESENTATION.md.

## Elapsed schedule contract

The anchor is a fixed instant rounded once to milliseconds. Every occurrence is anchor + ordinal × interval in elapsed minutes. Changing display time zone changes only the displayed clock, including repeated or absent daylight-saving hours. The interval does not create successor tasks and does not depend on when the user completes a task. A completed, deleted or inaccessible task must stop generating alerts through the existing task eligibility path.

The count, when present, is 1 through 999 and includes the anchor. Missed occurrences consume slots; reopening after sleep/offline must not send catch-up bursts. An optional end is inclusive, cannot precede the anchor, and the earlier of count/end wins. The default is no end, with the limited device queue replenished through the existing scheduling lifecycle. No claim of indefinite delivery while the app never runs is allowed. A preview/projection is capped at 60, before the existing combined device/Focus notification budget. Invalid or out-of-range inputs fail rather than silently clamp.

A schedule's semantic identity includes anchor, interval, count and end. It excludes display zone/locale. Notification identities and receipts must also include the task/spec identity, task incarnation, completion revision and exact original occurrence. A later callback may act only if the current accessible task still contains that exact occurrence under the same validated schedule. Snoozing must not shift the original anchor or mutate the task's planned date. Editing/deleting/disabling a reminder must invalidate its old actions; duplicates use normalized semantic identity.

## Interval implementation

Both apps now expose Interval in the native reminder editor. Presets use minutes/hours/days; custom whole minutes, optional total count and optional inclusive end remain editable. Upcoming alerts show up to five actual instants in the current display zone. Disabled ended schedules can be retained; enabled schedules require a future slot. Cancel leaves the task draft untouched. Done updates only that task's reminder settings; the containing editor retains its established save/autosave and Undo behavior. The review captures the workspace, task identity/incarnation and reminder rows. A changed workspace, replaced/deleted task or changed draft reminder collection cannot silently receive the old edit.

Version 3 uses kind `interval`, channels `["local"]`, and an `interval_schedule` object containing integer `start_ms`, `every_minutes`, optional `count`, and optional `until_ms`. Times are Unix milliseconds. Unknown extensions survive supported settings edits, backup and queue roundtrips. Removing a limit writes an explicit null, so a previous count/end cannot leak back into the new settings. The reserved planned-time ID cannot be used. Malformed settings are preserved as unsupported rows and produce no substitute planned-time alert.

Current local scheduling creates a separate notification identity for every occurrence, with an `r6` semantic signature covering the exact schedule, occurrence and task generation/completion revision. Response validation checks an exact original slot even when it is no longer in the future queue. Snoozing retains the original occurrence/anchor and changes only its fire time. The existing combined notification budget, retry and account-scope validation remain in use. These version-3 schedules are local-only, including on a device configured for a separate remote-delivery handoff: the current server explicitly excludes this format. The feature does not enable remote delivery.

A repeating task's successor carries the same interval schedule, including the original anchor, total count and end, as with the existing independent calendar reminders. It does not restart the count. The completed original task stops generating alerts; callback identity never retargets that original task's notification to its successor. This preservation also matches the tested previous readers, which retain the opaque row in successors.

## Compatibility and acceptance

The current hosted task check permits an array of up to 20 reminder objects. A read-only query confirms the existing server reminder validator excludes version 3. A synthetic read-only server projection also returns zero events for version 3 and one event for a version-1 relative positive control; `Scripts/fixtures/IntervalReminderServerExclusion.sql` reproduces that check. No database, policy, worker or account was changed. The previous committed Core reader from each repository is compiled by `Scripts/test_interval_old_reader.py --revision REVISION --output JSON`; it must show the row as unsupported, preserve it through edits/saving/successors, and emit no substituted alert. This proves those selected prior readers only, not universal older-client rollout enforcement. New clients perform full typed validation.

Independent Core cases cover malformed data, duplicate semantics, extensions/cleared limits, saved queue/portable backup, unique occurrences, exact response rejection, task generations, count inheritance, local-only handoff, queue retry/budget/snooze and account changes. Phone/tablet native checks and the actual simulator notification case are recorded separately in `p2-interval-reminders-evidence.json`, including failed iterations and exact remaining gates. Mac component rendering and successful builds are not full native acceptance.

Open gates include full Mac editing and VoiceOver, actual interval notification Complete/Tomorrow/Snooze actions through the OS UI, long-running replenishment across background/restarts, paired cloud/offline account transitions and wider localization/RTL/layout acceptance. Reviewed holiday policy is tracked in HOLIDAY_REMINDERS.md; location has a tested device-private lifecycle foundation, with native integration still unfinished; Time Sensitive presentation is tracked separately in REMINDER_PRESENTATION.md; the rest of rank 5 and Px remain incomplete. The user-deferred remote/rollout/release/provider work stays deferred.


## Recorded layouts

[mac light editor top](interval-reminders/mac-light-editor-top.png) · [mac dark editor bottom](interval-reminders/mac-dark-editor-bottom.png)

These are synthetic acceptance/component captures. Scrolling crops are expected; large-text content remains reachable through the native form. Mac captures are offscreen components, not full-app interaction evidence.


Country calendars now fetch automatically through Nager.Holidays Community v4, with nationwide/regional Public filtering and reviewed offline year snapshots. Calendar files remain secondary. See `HOLIDAY_REMINDERS.md` for source limits, privacy, refresh and commercial sponsorship requirements. This is not a silent multi-year subscription or completed rank-5 acceptance.


### 22 October — shared notification admission

Both independently owned schedulers now coordinate an optional location engine with the existing time/Focus queue. Cleanup precedes additions; durable location intents reserve at most 20 slots; Focus and explicit snoozes have priority; all other native pending requests consume capacity. Account/installation changes fence late work, and a full native queue produces waiting feedback instead of false snooze success. Normal Store location bootstrap/consent/task/action wiring remains unfinished and the location editor stays hidden. Every-visit mode, private desktop-to-phone authoring and positive capable-device location delivery remain open. See `LOCATION_REMINDERS.md` and `p2-notification-admission-evidence.json`; this milestone does not complete rank 5 or Px.


### 22 October — private consent and normal workspace lifecycle

The iOS Store now loads the protected private archive, installs the shared location engine during ordinary scheduling refreshes and rechecks account, workspace session, task and saved-place bindings around submissions. Account changes invalidate old work immediately; leaving and returning to the same account cannot acknowledge an old in-flight addition. Concurrent refresh callers wait for the latest hydration/admission pass. Both independently owned private stores persist explicit account consent in a version-2 private archive; legacy version 1 and a fresh identity start with consent off. Consent stays outside shared tasks, widgets and portable backups. Normal iOS cleanup handles revoked/unreadable/reset private state and preserves unrelated notification requests.

The Store allowance API refuses unsupported or unapproved native delivery and never prompts automatically. Public consent controls and task location editing are still absent; version-6 task rows remain opaque. The isolated normal-Store checks and precise remaining scope are recorded in `p2-location-workspace-evidence.json` and `LOCATION_REMINDERS.md`. Every-visit mode, private desktop-to-phone authoring, native response actions and positive capable-device location delivery remain open. Full rank 5 and Px remain incomplete.


### 22 October — reviewed location task drafts

Added the iOS reviewed Arrive/Leave/place/area editor and parent task Save/Cancel bridge behind the exact isolated DEBUG route. A memory-only review cannot arm an alert before a successful task save; ordinary builds still expose no location authoring. Normal iOS mutations now retire removed/undone location intents, including preparations that have not reached the OS. Private journal version 2 adds monotonic receipt revocations so restoring an old row cannot authorize a deliberately retired alert. Both repos own their compatible models and tests; Mac adds lossless phone/tablet reminder presentation without location permission.

This milestone is not full location-reminder or Px completion. Native actions/categories, durable recovery between a task commit and private retirement, capable-device delivery/permission acceptance, every-visit mode, private desktop-to-phone authoring and broader accessibility remain open. `LOCATION_REMINDERS.md` and `p2-location-task-drafts-evidence.json` separate the implemented editor from those remaining gates. User-deferred remote/release/older-client/provider work stays deferred.


### 22 October — durable location cancellation handoff

The iOS task-cache writer now atomically saves pending location cancellations with the task change, including sync/recovery writes. Outstanding cancellations survive snapshot replacement and Undo; acknowledgement is saved only after private-journal retirement. Relaunch replays either side of that handoff idempotently. Missing private authority and unreadable authority are treated separately; unreadable files retain their jobs and suppress location admission. Both repos own compatible, validated optional outbox models and independent tests; Mac adds no native location service. No names/geometry enter the outbox, widget projection or portable workspace export.

Exact verification is recorded in `p2-location-retirement-outbox-evidence.json`. This closes the volatile task-to-private-retirement gap for process termination; it does not claim power-loss durability, native location notification actions, repeated visits, private desktop-to-phone authoring or capable-device delivery. The reviewed editor stays experimental and rank 5/Px remain incomplete. User-deferred remote/release/older-client/provider work stays deferred.


### 22 October — location notification actions and durable explicit snoozes

Connected iOS Open/Complete/Tomorrow/Snooze routing, strict native boundary/followup decoding, fresh protected-state validation and atomic mutation receipts. A separately versioned local time-snooze namespace shares time/Focus/location capacity, preserves its target while waiting, reserves before OS submission and recovers without silently replaying consumed/ambiguous opportunities. Snoozing a snoozed alert creates a new explicit intent without rearming its boundary. The row shows the saved snooze date/time. Both repos own compatible ledger/queue models and tests; Mac gains no native location service.

Native integration exposed that calling Start local in an already-open readable local workspace reset its session and cleared native alerts. Both Stores now make that call idempotent; real workspace changes keep their cleanup. Evidence and precise limits are in `p2-location-notification-actions-evidence.json` and `LOCATION_REMINDERS.md`. Region-delivery/OS-origin boundary acceptance, repeated visits, private desktop-to-phone authoring, public setup/accessibility and safe action-history reclamation remain open. Normal authoring remains gated and rank 5/Px are incomplete; user deferrals remain unchanged.


### 22 October — explicit every-visit location reminders

The isolated iOS reviewed editor now offers Every visit until completed, defaulting to off. Version 7/reference 2/r10 and native v2 receipts distinguish it from unchanged one-shot rows. Both repos independently own journal-3 recovery epochs, repeated-trigger retention, per-delivery replay keys, compatible explicit time snoozes and cancellation/Undo fences. Mac describes the phone/tablet choice without gaining a location service.

Evidence is in `p2-location-repeat-evidence.json` and the current section of `LOCATION_REMINDERS.md`. Simulator drafts, response fixtures and genuine native time snoozes pass; these do not establish real region delivery or background/locked/cold callbacks. Normal authoring remains hidden. Public setup, private desktop-to-phone authoring, accessibility and history reclamation remain open. Rank 5/Px and other documented P2 gates remain incomplete; user deferrals are unchanged.


### 22 October — explicit ended location-action cleanup

Added a confirmed maintenance action in the experimental iOS editor to clear receipts whose exact private intent is permanently denied. Ordinary writes still preserve missing receipts, and active/actionable/unknown/other-account histories remain protected. Both repos independently own the policy and tests; Mac adds no location UI/service. A retired private tombstone continues rejecting old responses after cleanup and task Undo.

See `p2-location-action-cleanup-evidence.json` and `LOCATION_REMINDERS.md` for native save-failure/retry, cancellation/replay and UI evidence. This recovers capacity from known retired actions; unknown/previous-installation history, active-repeat rollover and full private identity-reset recovery remain gates. Public authoring, capable-device delivery, desktop-to-phone authoring and wider P2 acceptance remain incomplete. User-deferred remote delivery, general older-client rollout, distribution and genuine OAuth provider work stay deferred.


### 22 October — recoverable private location reset

Added a confirmed whole-device private reset to the experimental iOS Places flow. It writes a fresh consent-off private identity and durable reset receipt before clearing old action records; normal hydration finishes cleanup after a failed cache save or relaunch. A private writer lock and identity revalidation prevent stale reset proofs from deleting newer receipts. Tasks and unrelated time/Focus alerts are retained; old references require review. Both repos independently own the private archive-3 format and policy; Mac adds no location service or reset UI.

Exact native process-loss, selected previous-reader, Core and screenshot evidence is in `p2-location-reset-evidence.json` and `LOCATION_REMINDERS.md`. This closes the explicit reset/capacity-recovery implementation gap, not public authoring or genuine physical delivery/permission/account-switch acceptance. Wider location/P2 work and all user deferrals remain open.
