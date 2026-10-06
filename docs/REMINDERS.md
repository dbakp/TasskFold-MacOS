# Multiple reminders and delivery

Taskfold on iPhone and Mac now supports fixed-date reminders and offsets before or after a task’s planned time. The choices live on the task and sync through the durable edit queue. Each workspace has its own delivery switch on each device. Remote delivery remains part of P0; the native apps currently schedule local notifications after receiving task changes.

## Choosing reminders

Open a task’s Reminders screen. Keep **At planned time**, or add a fixed date and time, an offset before the plan, or an offset after it. Offsets support whole minutes up to seven days in either direction. A planned date without a time uses 8:00 AM. A task without a planned date retains its relative reminders as **Waiting for a planned date**; its fixed-date reminders can still fire. Identical enabled local reminders are rejected with a visible explanation.

Fixed-date reminders retain their instant when a task moves or the device changes time zone. Relative reminders move with the plan and use elapsed minutes across daylight-saving changes. Floating task times are projected in the device’s current time zone when Taskfold refreshes. The native trigger then uses an explicit UTC instant, preserving the second occurrence of an ambiguous autumn clock time. Closed-app travel still requires device testing and a background refresh strategy before promising that floating reminders follow a new local clock immediately.

On iPhone, reminder edits belong to the task editor’s draft: Save keeps them and Cancel discards them. The Mac inspector saves changes automatically; the custom-reminder sheet applies only after Done. Future reminder versions and additional fields are retained when supported settings change. Unsupported settings are identified and can be deleted explicitly. The limit is 20 settings per task, including the explicit planned-time setting.

Enable **Deliver reminders** to request system permission. Merely saving a dated task does not open a permission prompt. If permission is refused, the screen provides an explanation and a system-settings link. Delivery failures and deferred notifications are reported. Existing device-wide preferences migrate only to the first active workspace; signing into another workspace does not inherit them.

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

Todoist supports several reminder types, desktop/mobile/email channels, reminders for particular collaborators, and independently recurring reminder schedules. Taskfold now covers multiple fixed reminders and before/after offsets in both native editors, with relative offsets carried through task recurrence. It still needs remote channels, assigned reminder recipients, independently recurring reminders, configurable automatic offsets and snooze intervals, and reminder quick-entry grammar. Location and urgent reminders remain later platform work. [Todoist’s current reminder guide](https://www.todoist.com/help/todoist/features/introduction-to-reminders-9PezfU) is the comparison source.

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
