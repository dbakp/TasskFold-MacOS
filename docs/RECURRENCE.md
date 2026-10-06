# Repeat rules in Taskfold

Both native applications own the same persisted repeat vocabulary. Quick entry previews the full rule beneath its chips; task details exposes all its settings. A repeat phrase is a single chip, so declining it keeps its weekdays, start date, end date and occurrence limit literal. Unsupported phrases remain in the title with feedback.

## Quick entry

| Example | Result |
| --- | --- |
| `Review every weekday` | Monday through Friday, starting on the next eligible day including today |
| `Tidy every weekend` | Saturday and Sunday |
| `Check every mon, wed and fri` | One weekly rule with three selected weekdays |
| `Review every 2 weeks on monday and friday` | Selected weekdays, with a two-week cycle |
| `Water every other day` | Two-day interval |
| `Reconcile every month on the 31st` | Month-end clamping, retaining the requested 31st for later months |
| `Report every 2 months on last friday` | Last Friday in each two-month cycle |
| `Meet every fifth monday` | Fifth Monday of the month; months without one are skipped |
| `Celebrate every year on february 29` | February 29, using February 28 in non-leap years |
| `Service every! 3 months` | Three months from the actual completion day |
| `Review every week starting 2027-01-01 until 2027-06-30` | Explicit first date and inclusive end limit |
| `Practice every day for 5 occurrences` | Five occurrences including the current task |

Daily, weekly, monthly, yearly, numeric intervals (1–365), `other`, full/three-letter weekday names, weekday sets, first/second/third/fourth/fifth/last monthly weekdays, explicit calendar days, `starting`/`from`, `until`/`ending`, and occurrence limits can be combined with ordinary times, reminders, priorities, labels, project references, estimates and deadlines. Start/end dates in these phrases use `YYYY-MM-DD`. A bare single weekday retains the existing next-weekday behavior; an explicit starting date is inclusive. Quoted or backslash-escaped phrases stay literal. Multiple repeat phrases require choosing one rule.

## Completing and editing

Scheduled rules retain their calendar rhythm. Completing late skips dates already passed, rather than creating another overdue occurrence. Missed dates do not consume the remaining occurrence limit. `every!` starts each interval from the day the task was actually completed; explicitly chosen weekdays/calendar days are applied after waiting that full interval. Date-based repeat rules keep the task's planned time; they do not add a timer or hourly occurrences.

A completion creates one stable, create-only successor using the existing guarded queue. It preserves the task's useful fields, renews checklist identities, advances child plans, decrements its occurrence limit once, and clears a one-off deadline/absolute reminder. Reopening does not create another successor. End dates are inclusive. Gregorian civil days and fixed-time source zones preserve the rule across DST and travel. Floating tasks use the device's current zone.

The native Repeat editor includes yearly/month/day, monthly ordinal/weekday, completion anchoring, end date, count, and a next-occurrence preview. Turning on repeating for an undated task supplies its first date. Changes follow each platform's normal draft/save or inspector autosave behavior. Rich rules remain JSON in the existing `recurrence_pattern`; no new backend schema or sibling repository dependency is required. Export, restore and the durable offline queue preserve the new fields.

Taskfold's useful public behavior was compared with [Todoist's recurring-date documentation](https://www.todoist.com/help/todoist/features/introduction-to-recurring-dates-YUYVJJAV), checked 6 October 2026. This is not full natural-language parity: named start/end dates, multiple monthly dates, sub-day rules, holidays, and independently recurring reminder phrases remain outside this grammar. Autocomplete is still pending. Native paired-device/offline replay, Mac runtime and physical/iPad acceptance remain recorded separately in the P0 tracker.
