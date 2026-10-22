# Advanced reminder delivery plan

This is rank 5 of P2_PLAN.md. It does not reopen server delivery or release verification. Ordinary local alerts remain subject to the device's permission, delivery settings and scheduling budget. The task's repeat rule and an independent reminder schedule remain separate concepts.

## Delivery order

1. **Elapsed repeating reminders.** Add an opt-in Interval choice beside From plan, Fixed time and Repeats. The user chooses the first instant and a whole-minute interval from 5 minutes through 7 days. Offer 15/30/60-minute presets plus a custom value. Show the next five actual dates/times with the current display zone before saving. Never infer an interval from free text that the user has not reviewed.
2. **Travel clarity.** Label interval reminders as elapsed time. Existing calendar reminders retain their saved source-zone clock; fixed reminders retain their instant. The editor now offers a named-zone chooser and compares up to five actual source/device clock times, including offset changes. See REMINDER_TIME_ZONES.md. A future follow-my-current-zone clock is a separate explicit choice, not a migration of existing schedules.
3. **Holiday policy.** Offer explicit Skip or Move policies only after a reviewed holiday source/region, source updates, date boundaries and count/end semantics are agreed. Do not infer holidays from a device locale, silently change task dates or couple a user's private calendar to shared reminders. Automatic country/year public calendars are the primary source, with reviewed finite snapshots and optional all-day calendar files. Independent reminder Skip/Move policies are implemented in `HOLIDAY_REMINDERS.md`. Silent multi-year subscriptions remain unfinished; provider commercial sponsorship and genuine delivery acceptance stay open.
4. **Location reminders.** Define arrival/departure, location precision, opt-in permissions, device ownership, background/reinstall recovery, data retention and unsupported-platform presentation before requesting location access. Cross-platform editing must preserve unsupported settings. No location permission or background tracking is added by this milestone.
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

Open gates include full Mac editing and VoiceOver, actual interval notification Complete/Tomorrow/Snooze actions through the OS UI, long-running replenishment across background/restarts, paired cloud/offline account transitions and wider localization/RTL/layout acceptance. Reviewed holiday policy is tracked in HOLIDAY_REMINDERS.md; location remains unimplemented; Time Sensitive presentation is tracked separately in REMINDER_PRESENTATION.md; the rest of rank 5 and Px remain incomplete. The user-deferred remote/rollout/release/provider work stays deferred.


## Recorded layouts

[mac light editor top](interval-reminders/mac-light-editor-top.png) · [mac dark editor bottom](interval-reminders/mac-dark-editor-bottom.png)

These are synthetic acceptance/component captures. Scrolling crops are expected; large-text content remains reachable through the native form. Mac captures are offscreen components, not full-app interaction evidence.


Country calendars now fetch automatically through Nager.Holidays Community v4, with nationwide/regional Public filtering and reviewed offline year snapshots. Calendar files remain secondary. See `HOLIDAY_REMINDERS.md` for source limits, privacy, refresh and commercial sponsorship requirements. This is not a silent multi-year subscription or completed rank-5 acceptance.
