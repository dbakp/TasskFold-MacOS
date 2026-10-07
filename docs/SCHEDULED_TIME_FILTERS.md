# Scheduled time filters

Both native apps own this behavior and its build inputs independently. Update both apps before editing these conditions across devices.

## Choosing work by clock

The visual builder offers **Time at**, **Time before** and **Time after**. They compare the task’s scheduled minute in the viewer’s current time zone, on any day. Add **Planned on: today** to select today’s work. Examples:

| Expression | Result |
| --- | --- |
| `today & time before:2pm` | Today’s timed work before 14:00 |
| `time:09:00` | Timed work at 09:00 on any day |
| `date:tomorrow & time after:6pm` | Tomorrow’s timed work after 18:00 |
| `date before:today at 2pm` | Timed work scheduled before today’s 14:00 boundary, including earlier days |
| `effective-due:tomorrow at 09:00` | Work with a planned time at tomorrow’s 09:00 boundary |

Use `HH:mm` or an AM/PM clock, such as `2pm`, `2:30 PM`, `12am` or `12pm`. Values persist as a zero-padded 24-hour minute. Times such as `25:00`, unknown zones, invalid task dates and malformed clocks cannot become matches. Native `HH:mm` and PostgreSQL `HH:mm:ss` task values both work; comparisons use minute precision, matching the existing planning engine.

## Date and time boundaries

**Planned on/before/after** and **Due on/before/after** accept a date phrase followed by `at` and a clock. Their canonical persisted values are, for example, `tomorrow at 14:00`. Relative dates remain relative. The chosen boundary uses the viewer’s current time zone; fixed-zone task plans use their actual scheduled instant, while floating plans resolve in the viewer’s zone.

Time-only before/after excludes the chosen wall minute. Date-and-time on selects the resolved minute; before ends at its start and after starts at the next minute. A repeated boundary uses the first occurrence; a clock gap advances to the next valid minute on that civil day. A saved second-fold task keeps its actual instant, so it is after a first-fold boundary even though its displayed wall clock is the same. Time-only conditions match either fold by its displayed minute. Whole missing civil days produce no boundary.

Tasks without a planned date and valid time are excluded from timed conditions. An effective-due timed condition does not turn a deadline-only or all-day task into a midnight event. Deadline conditions continue to accept dates only. Date-only filters retain their existing semantics and deadline fallback. Combine `no time` using OR when you want to include all-day work explicitly.

## Persistence, capture and widgets

Three additive version-1 predicate fields are `planned_time_on`, `planned_time_before` and `planned_time_after`. Existing planned/effective-due fields also accept the validated date-and-time value grammar. There is no schema, table, permission or task-field migration. Saved-view queues, cache encoding and portable backups retain the canonical AST; restoring to another account remaps project/label/section identities without rewriting time references.

Time predicates and dated-time predicates do not invent capture defaults. Existing independent project/label/priority and date-only defaults still apply. Saving a filter does not alter the tasks it selects.

Membership depends on the task data, viewer zone and evaluation civil day, never the current intra-day clock. The existing cache day/zone identity and eight-day widget membership therefore remain sufficient. Widgets receive matching IDs, not query text; zone changes or projection expiry request refresh. DST and chosen folds are resolved separately for each projected day. This does **not** implement `now`, `+4 hours` or sliding windows; those require timed cache refresh and widget validity intervals.

## Compatibility and remaining port work

Older clients must preserve unsupported query documents, show an unavailable-query state and refuse saving a replacement query. The previous unsupported-query preservation baseline is required; updating both native clients is a rollout gate. Both apps own their sources, tests and release inputs, with no build dependency on the sibling repository.

Todoist documents a comparable `date: today & date before: today at 2pm` workflow. [Todoist’s filter reference](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH).

Sliding instant windows, configurable next-week rules, richer natural grammar, ordered comma-separated result sections, hierarchy/collaboration predicates and signed-in paired native acceptance remain planned. Current verification and platform limitations are recorded in each repository’s validation/implementation documents; this checkpoint does not complete P0.
