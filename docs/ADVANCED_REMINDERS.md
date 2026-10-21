# Advanced reminder delivery plan

This is rank 5 of P2_PLAN.md. It does not reopen server delivery or release verification. Ordinary local alerts remain subject to the device's permission, delivery settings and scheduling budget. The task's repeat rule and an independent reminder schedule remain separate concepts.

## Delivery order

1. **Elapsed repeating reminders.** Add an opt-in Interval choice beside From plan, Fixed time and Repeats. The user chooses the first instant and a whole-minute interval from 5 minutes through 7 days. Offer 15/30/60-minute presets plus a custom value. Show the next five actual dates/times with the current display zone before saving. Never infer an interval from free text that the user has not reviewed.
2. **Travel clarity.** Label interval reminders as elapsed time. Existing calendar reminders retain their saved source-zone clock; fixed reminders retain their instant. The editor must distinguish these behaviors and preview clock changes. A future follow-my-current-zone clock is a separate explicit choice, not a migration of existing schedules.
3. **Holiday policy.** Offer explicit Skip or Move policies only after a reviewed holiday source/region, source updates, date boundaries and count/end semantics are agreed. Do not infer holidays from a device locale, silently change task dates or couple a user's private calendar to shared reminders. No holiday behavior is implemented by this milestone.
4. **Location reminders.** Define arrival/departure, location precision, opt-in permissions, device ownership, background/reinstall recovery, data retention and unsupported-platform presentation before requesting location access. Cross-platform editing must preserve unsupported settings. No location permission or background tracking is added by this milestone.
5. **Urgent presentation.** Define the explicit user choice and available OS capability before adding elevated presentation. Never label ordinary alerts as critical, guaranteed or emergency delivery. Keep normal delivery available. No urgent behavior is enabled by this milestone.

## Elapsed schedule contract

The anchor is a fixed instant rounded once to milliseconds. Every occurrence is anchor + ordinal × interval in elapsed minutes. Changing display time zone changes only the displayed clock, including repeated or absent daylight-saving hours. The interval does not create successor tasks and does not depend on when the user completes a task. A completed, deleted or inaccessible task must stop generating alerts through the existing task eligibility path.

The count, when present, is 1 through 999 and includes the anchor. Missed occurrences consume slots; reopening after sleep/offline must not send catch-up bursts. An optional end is inclusive, cannot precede the anchor, and the earlier of count/end wins. The default is no end, with the limited device queue replenished through the existing scheduling lifecycle. No claim of indefinite delivery while the app never runs is allowed. A preview/projection is capped at 60, before the existing combined device/Focus notification budget. Invalid or out-of-range inputs fail rather than silently clamp.

A schedule's semantic identity includes anchor, interval, count and end. It excludes display zone/locale. Notification identities and receipts must also include the task/spec identity, task incarnation, completion revision and exact original occurrence. A later callback may act only if the current accessible task still contains that exact occurrence under the same validated schedule. Snoozing must not shift the original anchor or mutate the task's planned date. Editing/deleting/disabling a reminder must invalidate its old actions; duplicates use normalized semantic identity.

## Current state and next gates

Each app independently owns ReminderIntervalSchedule.swift and its tests, compiled by its Core package and app target. The model seeks directly to the current interval without scanning years of missed slots. It supports exact-slot validation, bounded projection, count/end limits and canonical identity. It neither writes task data nor registers notifications. There is no new menu option yet, no new persistent envelope and no change to existing reminder delivery.

The next implementation must connect a versioned independently preserved spec, typed native editor/preview, task-save/Undo, import/export, source/account guards, DueReminder projection/signatures and real notification response validation. Inspect current server/import/write validation and older-reader behavior before enabling persistence. Do not make a new schedule silently look like a planned-time alert to an older client. The deferred general old-client rollout work stays deferred; a feature cannot claim compatibility without its own evidence.

Acceptance must cover phone/tablet correction and Cancel, full saved spec after normal relaunch, Mac native editing when available, large text/VoiceOver, count/end expiry, task completion/reopen, stale schedule callbacks, local queue limits, background/reschedule behavior, offline retry and account/task reincarnation. Real delivery is distinct from Core arithmetic and successful builds. Current foundation evidence is in p2-interval-reminder-foundation-evidence.json. Rank 5 and the full Px backlog remain incomplete.
