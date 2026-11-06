# Reminder time zones and travel preview

Open a task's Reminders, add or edit a Repeats reminder, then choose Time zone. Search by city or a named zone. Choosing a result changes the proposal; Done and the containing task editor's existing save/autosave keep it. Cancel in either review preserves the original settings. Use current time zone is an explicit change, not an automatic migration when the device travels.

The preview shows up to five actual upcoming alerts in the saved zone. When the device uses another zone, each row also shows On this device with that clock and zone. A note identifies an offset change within those dates, whether it occurs in the saved zone or the device's zone. Identical zone identifiers omit the duplicate device clock. Dates wrap at accessibility text sizes and remain in the scrollable form.

Calendar reminders keep their authored clock in the saved zone. Changing that zone intentionally moves the alert instants while retaining the selected calendar day, clock, repeat rule and total limits. The task's planned date/time/zone remain separate. Interval reminders retain elapsed spacing; fixed-time reminders retain their instant. From-plan reminders use the task’s planned instant; a date without a time uses 08:00 in the device zone when the local schedule is calculated. No follow-the-device floating clock, holiday policy, location tracking or urgent presentation is introduced here.

## Civil-day safety

A date picker uses a calendar date representation. Zone changes read and write through the same Gregorian picker calendar and verify the resulting era/year/month/day. Noon avoids an ordinary midnight transition; a genuinely skipped date is refused rather than rolled into tomorrow. This representation stays separate from the existing proleptic Gregorian notification resolver. Years 1 through 9999 and historical cutover behavior are tested; the initial focused test exposed that mixing the two representations could reject a valid picker date.

The saved schedule still uses the existing version-2 envelope and named time_zone field. No new persistent field, signature version, migration or server delivery is added. The existing semantic signature includes the selected zone, so a saved change invalidates old occurrences/actions. Merely reading/searching/comparing clocks cannot change that signature or write a task. Named-zone choices come from the device's Foundation database; a fixed-offset device clock is supported for display, with UTC as the explicit default for a new named-zone schedule if the device has no supported named identifier.

The existing reminder editor's workspace/task-incarnation/source-row guards, durable save/Undo, backup and queue behavior remain responsible for mutations. The chooser holds no credentials, fetches nothing and reads no calendar events. Provider registration and all user-deferred remote/release/older-client work remain deferred.

## Verification

ReminderTravelTests in each repository covers named search, current-zone fallback, civil-day moves, Samoa's skipped date, a midnight transition, invalid/nonfinite inputs, domain edges, source/device offset changes, same-zone deduplication, bounded previews, locale/fixed-offset display and unchanged reminder/action identity until an actual saved zone edit. Both apps own their source and tests.

Phone/tablet native cases exercise picker Cancel, searchable selection, two-clock review, source/clock/rule/limit and task-plan preservation, task Save, normal relaunch, Use current time zone followed by Cancel, largest-text dark chooser/preview and untouched saved data after Cancel. Exact actual runs and any failures are in p2-reminder-time-zones-evidence.json. The Mac's Scripts/render_reminder_travel.py renders production editor/picker bodies with read-only synthetic state and its owned tested Core; offscreen components and compilation are not full native interaction.

Remaining acceptance includes full Mac keyboard/VoiceOver interaction, an actual OS zone change while the app is foreground/background, cloud/paired-client and broader localization/RTL checks. The previously recorded interval notification-action and replenishment gates remain open. This advances travel clarity, not the full rank-5 or Px backlog.


## Recorded layouts

[mac light editor](reminder-time-zones/mac-light-editor.png) · [mac dark clocks](reminder-time-zones/mac-dark-clocks.png)
