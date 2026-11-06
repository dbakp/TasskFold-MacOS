# Relative day-window filters

Both native apps own their parser, evaluator, editor and tests. No sibling repository is a build input.

## Meaning

| Expression | Date source | Included days |
| --- | --- | --- |
| `3 days` or `date:3 days` | Planned date | Today, tomorrow and the day after |
| `-3 days` or `date:-3 days` | Planned date | Three days ago through yesterday |
| `effective-due:3 days` / `effective-due:-3 days` | Planned date, falling back to deadline only without a plan | Same future/past boundaries |
| `deadline:3 days` / `deadline:-3 days` | Independent deadline | Same future/past boundaries |

Counts must be whole numbers from 1 through 3650. Singular `day` and quoted values are accepted. Future ranges include today and exclude today + N; past ranges include today − N and exclude today. These are civil calendar days, not elapsed 24-hour intervals. Timed plans use the viewer's current time zone before comparing their day. Deadlines remain floating civil dates. Missing dates do not match a positive range; ordinary Boolean negation applies.

`in 3 days` still selects one exact date. `3 days ago` and `created:-3 days` keep their previous exact-date meaning. Existing `next N days`, `deadline:nextN`, `due`, Today and Overdue keep their stored semantics. Bare ranges follow Taskfold's established planned-date convention; `effective-due:` explicitly requests deadline fallback. Before/after operators do not accept ranges. Ranges cannot include an `at` clock. A saved range never supplies a capture date or deadline.

The visual editor offers future/past conditions under Planned dates, Effective due and Deadlines. It explains inclusion boundaries, defaults to three days, and disables Save for invalid counts. Expression mode canonicalizes ranges as an explicit date-source query. Conditions remain editable after switching modes and relaunching.

The [official Todoist filter reference](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH), checked 9 October 2026, documents positive and negative multi-day syntax. The boundary table above is Taskfold's explicit contract; the reference's short past-days description does not establish every boundary detail.

## Persistence and compatibility

Version-1 predicates add `planned_next_days`, `planned_past_days`, `effective_due_next_days`, `effective_due_past_days`, `deadline_next_days` and `deadline_past_days`. Values are canonical positive decimal counts. There are no schema columns, migrations, new operators or automatic rewrites of existing queries. Both repos independently validate and evaluate these fields. Queued saved-view records and backups preserve relative counts; restoring into another account keeps the range relative to that account's current day.

Both devices must have this capability before editing these predicates. An older safe reader must preserve the entire unsupported query, expose its unsupported state and disable destructive editing; it must not substitute Today or an empty successful result. The prior preservation baseline is iOS `c8d96f8` / Mac `362b3ad`; older clients still require upgrading. Actual mixed-version/paired-native acceptance remains open.

Cache identity already includes the viewer's day and zone, and task updates invalidate membership. Widgets receive account-bound day-to-ID projections for eight days; they do not receive the query AST. No intra-day clock refresh capability is required for these civil-day windows. Physical configured-host and cross-device refresh acceptance remains open.

## Verification status

Both independently owned packages pass 583 tests in Debug and optimized configurations, each with four optional integration skips and zero failures. Tests cover parsing/serialization, invalid counts, exact-offset compatibility, Boolean/comma composition, date-source precedence, inclusive/exclusive boundaries, DST/leap/year transitions, fixed-plan viewer zones, cache day/task changes, queued offline persistence, backup account remapping and private eight-day widget projections.

Both own native Debug and Release builds pass; Release app/widget binaries include arm64 and x86_64. The isolated iOS test product runs two actual cases on each of iPhone 17 Pro and iPad Pro 11-inch (M5): four passes, no failures/skips or reported runtime warnings. Each light/default or dark/largest-text walk chooses the visual range condition, rejects zero, saves a one-day effective-due range, checks planned/deadline-only membership and plan precedence, changes to a planned-date expression, saves, relaunches and reopens the retained condition. Wider and past ranges are covered by Core tests, not by these native walks. Mac runtime remains restricted.

All 12 retained original PNGs were individually viewed and copied byte-for-byte into `day-window-previews/`. Default-size controls and feedback are readable; largest condition/error/expression text wraps and Save stays available. Largest forms/help require scrolling; the iPad validation capture shows part of the numeric field below the viewport, and the passing walk scrolls to edit it. The largest iPhone list navigation title truncates, and translucent toolbar underlap remains. This is scoped range-flow evidence, not full accessibility or full-surface acceptance.

[Exact inputs, commands, terminal results, product hashes and screenshot provenance](day-window-evidence.json). Initial focused tests caught and corrected a parser interception regression; their diagnostic logs remain in `/tmp/taskfold-day-window-ios-focused*.log`. All final eight build/Core jobs and four native cases use the unchanged frozen v1 inputs. Existing compiler warnings are retained in the build logs; only the native test result summaries establish zero runtime warnings.

The full P0 objective remains open, including broader grammar/hierarchy/collaboration, full-surface accessibility, actual paired/offline/revocation/restore flows, restricted Mac runtime, real provider-account import, provisioned widgets, background delivery and distribution.
