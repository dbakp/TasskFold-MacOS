# Multiple reminders and delivery

Taskfold on iPhone and Mac now supports fixed-date reminders and offsets before or after a task’s planned time. The choices live on the task and sync through the durable edit queue. Each workspace has its own delivery switch on each device. Remote delivery remains part of P0; the native apps currently schedule local notifications after receiving task changes.

## Choosing reminders

Open a task’s Reminders screen. Keep **At planned time**, or add a fixed date and time, an offset before the plan, or an offset after it. Offsets support whole minutes up to seven days in either direction. A planned date without a time uses 8:00 AM. A task without a planned date retains its relative reminders as **Waiting for a planned date**; its fixed-date reminders can still fire. Identical enabled local reminders are rejected with a visible explanation.

Fixed-date reminders retain their instant when a task moves or the device changes time zone. Relative reminders move with the plan and use elapsed minutes across daylight-saving changes. Floating task times are projected in the device’s current time zone when Taskfold refreshes. The native trigger then uses an explicit UTC instant, preserving the second occurrence of an ambiguous autumn clock time. Closed-app travel still requires device testing and a background refresh strategy before promising that floating reminders follow a new local clock immediately.

On iPhone, reminder edits belong to the task editor’s draft: Save keeps them and Cancel discards them. The Mac inspector saves changes automatically; the custom-reminder sheet applies only after Done. Future reminder versions and additional fields are retained when supported settings change. Unsupported settings are identified and can be deleted explicitly. The limit is 20 settings per task, including the explicit planned-time setting.

Enable **Deliver reminders** to request system permission. Merely saving a dated task does not open a permission prompt. If permission is refused, the screen provides an explanation and a system-settings link. Delivery failures and deferred notifications are reported. Existing device-wide preferences migrate only to the first active workspace; signing into another workspace does not inherit them.

## Reminders in quick entry

Add reminders while capturing or editing a task. `Call Sam tomorrow at 4pm !30mb !2h !tomorrow 9am` creates a task planned for tomorrow at 4 PM with three custom reminders: 30 minutes before the plan, two hours after acceptance, and tomorrow at 9 AM. The existing planned-time reminder stays enabled unless the task already opted out. Reminder times never become the task’s planned date or time.

| Shortcut | Meaning |
| --- | --- |
| `!30m`, `!2h30m`, `!1d` | A fixed instant this many elapsed minutes/hours/days after accepting the entry |
| `!30mb`, `!1h before` | This offset before the task’s planned time; follows rescheduling and task recurrence |
| `!30ma`, `!45min after` | This offset after the task’s planned time |
| `!0mb` | Enable the planned-time reminder, preserving any extra fields on that setting |
| `!3pm`, `!15:00` | The next occurrence of this clock time in the current device time zone |
| `!tomorrow 9am`, `!tmr at 15:00`, `!Mon 9am`, `!2026-10-12 9am` | A fixed local date/time converted to an instant when accepted |
| `!tomorrow` | Tomorrow at 9 AM |
| `!later` | Exactly four elapsed hours after acceptance |

Tap a reminder chip’s cross to keep that expression in the title. Each reminder can be declined independently. In the iPhone composer, manually choosing a project, date or priority retains declined choices until the text is cleared. `\!tomorrow 9am` keeps the entire expression as prose, and `"!tomorrow 9am"` remains quoted text. URLs and expressions attached to another word are literal. An invalid, duplicate or over-limit expression stays in the title with feedback. Existing reminder settings, unsupported versions and explicit planned opt-out are retained when adding another reminder. Without a plan, a relative shortcut waits for a planned date; date-only tasks use 8 AM.

On iPhone, multiple reminder shortcuts carry into **More options**, save with the task and survive relaunch. Both platforms use the same persisted reminder contract; the Mac capture/inspector/relaunch walk still needs runtime validation. The capture/editor surfaces explain when delivery is off on this device; saving a reminder never requests notification permission by itself. Enable delivery explicitly in the task’s Reminders screen. A fixed-date shortcut belongs to one task occurrence; before/after shortcuts carry to its successor. Independently recurring shortcuts such as `!every sat 9am` remain literal with an explanation until their occurrence model is implemented. `!later` is exact elapsed time; this differs from Todoist’s rounded shorthand. [Todoist’s reminder shortcut guide](https://www.todoist.com/help/todoist/features/introduction-to-reminders-9PezfU) documents the `!30m` versus `!30mb` distinction used here.

Explicit fixed dates in the past are rejected. A spring clock gap advances to the next valid local time; an ambiguous clock uses its first occurrence. This instant then stays fixed during travel. Reminder offsets support at most seven days, and all settings together retain the 20-row bound. Autocomplete and independently recurring reminder schedules remain open work.

## Scheduling and notification actions

Taskfold schedules the nearest 60 upcoming notifications, including snoozes, and refreshes the queue after edits, sync and foreground/significant-time changes. Later reminders need a subsequent refresh. The operating system can deliver already scheduled local notifications while the app is closed, subject to system permission and notification settings. [Apple’s local notification documentation](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) describes this delivery model.

Complete, Remind me in 1 hour, and Move to tomorrow remain available. A notification carries the receiving workspace, task, reminder ID and schedule signature. The app checks these against its current accessible tasks before acting or showing a reminder banner. A stale notification cannot edit a task in another account. Snoozes survive unchanged refreshes, retry after scheduling failures, and are canceled after their task completes, disappears or changes schedule. Disabling delivery or signing out clears Taskfold reminders and snoozes; unrelated notification categories are preserved.

Completing a recurring task carries its relative reminders to the next occurrence. Fixed-date reminders belong to that occurrence and do not repeat. An explicit off setting prevents dropping the last fixed reminder from accidentally restoring the old implicit planned-time notification. Independent recurring reminder schedules remain future work.

## Persisted contract

`tasks.reminder_specs` is a JSON array with stable UUID IDs and `version: 1`. An empty array retains the legacy implicit planned-time reminder when delivery is enabled. A nonempty array is the complete explicit override. The reserved planned-time ID is `00000000-0000-4000-8000-000000000001`; its relative offset is zero, and `enabled: false` records a task-level opt-out.

```json
{
  "version": 1,
  "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "kind": "relative",
  "anchor": "planned",
  "offset_minutes": -30,
  "channels": ["local"],
  "enabled": true
}
```

```json
{
  "version": 1,
  "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  "kind": "absolute",
  "at": "2026-10-25T01:30:00Z",
  "time_zone": "Europe/Copenhagen",
  "channels": ["local"],
  "enabled": true
}
```

The native clients deliver only `local` entries. `push` and `email` are recognized channel names for future integration; this milestone does not send them. Unsupported or malformed entries are preserved and excluded from scheduling. Scheduling bounds malformed oversized local data to 20 rows. Backup validation already enforces the same array bound. Edits to reminders use the existing guarded task RPC; overlapping reminder-array edits require conflict review.

## Remaining Todoist reminder gaps

Todoist supports several reminder types, desktop/mobile/email channels, reminders for particular collaborators, and independently recurring reminder schedules. Taskfold now covers multiple fixed reminders and before/after offsets in both native editors, with relative offsets carried through task recurrence. It still needs remote channels, assigned reminder recipients, independently recurring reminders, configurable automatic offsets and snooze intervals, and independently recurring reminder quick-entry grammar and autocomplete. Location and urgent reminders remain later platform work. [Todoist’s current reminder guide](https://www.todoist.com/help/todoist/features/introduction-to-reminders-9PezfU) is the comparison source.

## Remote delivery implementation plan

| Step | Required implementation | Acceptance |
| --- | --- | --- |
| Register devices | Authenticated, owner-scoped device registrations containing platform, bundle, environment, token, time zone, permission and delivery choice. Rotate tokens, expire stale registrations and detach them on sign-out. Keep APNs credentials on the backend. | Two accounts cannot read or alter each other’s devices. Token replacement and sign-out leave no active old registration. |
| Reconcile events | A service-only worker projects enabled specifications into per-recipient occurrences. Use an explicit recipient model before supporting collaborator reminders. Reconcile after edits, completion, recurrence, access revocation and deletion; scan a bounded catch-up window after downtime. | Exactly the expected events remain after each mutation. A revoked collaborator receives no new job. Fixed instants and DST/travel projections match native fixtures. |
| Record delivery | Private job/delivery records identify task, reminder, occurrence, recipient, channel and device. Claim jobs atomically with leases, bounded retries, backoff and a failed-job path. Check current permission, access and signature immediately before dispatch. | Concurrent workers and retries produce one logical event; a changed or completed task cancels unaccepted work. Worker downtime and transient failures recover without losing events. |
| Connect providers | Implement APNs sandbox/production routing and optional email delivery. Validate native bundle entitlements and token registration separately in the iOS and Mac release pipelines. Handle invalid tokens and provider errors without exposing credentials or private task text in logs. | A physical iPhone and a signed Mac receive the expected reminder with the app closed. Provider failures appear in operational diagnostics; invalid tokens are retired. |
| Prevent duplicate alerts | Define one delivery authority per event/device when remote delivery is enabled. Generate canonical signature test vectors shared by worker and both native clients, plus stable event IDs and provider collapse/idempotency keys. Reconcile local fallback requests on reconnect and on remote receipt; do not dispatch both routes independently. | The same event arriving through retry, reconnect or local fallback yields one actionable alert on each intended device. Old-account actions fail closed. |
| Verify and release | Add fake-provider tests, rolled-back multi-user SQL fixtures, two-session native transport tests and physical-device/background walks. Cover offline edits, closed-app edits from another device, rescheduling, completion, snooze, travel, permission changes and account switching. Add a staged rollout switch and an operations guide. | No complete remote-delivery claim until provider, physical-device, cancellation and duplication checks pass. Each native repo builds and releases with its own registered inputs. |

The existing web-owned `check-due-tasks` source uses one OneSignal subscription per profile and a task-level `notification_sent_at`. It selects a due clock minute rather than versioned reminder occurrences. It needs replacement/reconciliation for this contract; it cannot establish native APNs delivery or multi-reminder retry/cancellation semantics. Its cron authorization must fail closed when configuration is missing. Provider credentials and device registration are explicit dependencies, and the current deployed configuration must be inspected before enabling a replacement.


## 6 October: completion-cycle reminder cancellation

Both native clients now include the server-owned completion revision in reminder signatures. Once a complete/reopen cycle is observed, a notification or snooze from before that cycle cannot act on the reopened task, even when its planned instant is unchanged. Missing legacy revisions and revision zero use the same signature; unrelated title edits do not invalidate the schedule. Stable request identifiers let the scheduler replace obsolete notifications. This is native scheduling/action validation, not evidence of remote delivery. The future worker/native canonical-signature vectors must include this revision and the existing specification/instant fields.


## Focus finish alerts and the shared device budget

The Focus screen owns a separate, default-off, per-workspace device choice. One current finish alert reserves one of the same 60 pending request slots, leaving 59 for the nearest enabled task reminders and snoozes. Without a Focus alert, task reminders keep all 60. Task counts/failures in the reminder editor exclude Focus; the Focus screen reports its own scheduling status. Turning either preference off reconciles only its own events through the shared serialized scheduler.

Focus uses the `taskfold.f1.` namespace and `taskfold.focus.finished` category, while ordinary reminders retain their existing `taskfold.r2.` identifiers and actions. Focus has no Complete/Snooze/Tomorrow actions. Pause/end/replacement, task completion/removal, sync conflict, unreadable workspace and sign-out invalidate old requests/receipts. Task completion revisions also invalidate alerts across complete/reopen cycles. [Focus behavior and outstanding acceptance](FOCUS_SESSIONS.md#finish-alerts-on-this-device) describe the contract. No APNs worker, device registration or independent remote reconciliation is added by this milestone.
