# Creation-date filters

Both native apps own their implementation, tests and build inputs. Creation dates make it possible to review neglected work (`created before:-30 days`) or recent additions (`created after:yesterday`) independently of plans and deadlines.

## Contract and semantics

The existing version-1 AST gains three predicate capabilities: `created_on`, `created_before`, and `created_after`. Their expression forms are `created:`, `created before:`, and `created after:`; `created on:` is accepted as an explicit alias. The builder exposes Created on/before/after and explains the date source and exclusive day boundaries.

Values use the existing strict civil-date reference grammar: ISO dates, today/tomorrow/yesterday, weekdays, named dates, bounded exact calendar-day offsets, and the other supported date-only phrases. The Todoist-style `-N days` form is accepted **only for creation predicates** and canonicalized to `N days ago` (0–3650; zero becomes `today`). It never becomes a multi-day window. Clock times, ambiguous next week and unsupported phrases are rejected. Invalid creation values get creation-specific date-only guidance; the error never recommends adding a time or mentions an unrelated deadline. Other saved date predicates retain their previous meaning and grammar.

Recorded `created_at` instants, including fractional seconds and UTC offsets, are converted to the viewer's Gregorian civil day. Date-only legacy metadata retains its recorded civil day. Missing, malformed, impossible dates or unzoned timestamps never acquire a fallback from the plan, deadline, current clock, recurrence parent or import date. Before and after exclude the entire boundary day; on matches the whole day. Excluding a creation condition uses ordinary Boolean negation, so unknown dates can match its negation. Include completed retains the existing view behavior.

Relative offsets add calendar days across DST, leap years and travel. Membership changes at civil midnight or on a zone change; existing cache keys and the eight-day widget projection already include those inputs. Widget data contains matching IDs, never raw creation timestamps or the private AST. Expired projections require refresh. Creation conditions do not manufacture a creation timestamp or planning fields for task capture.

## Persistence and rollout

No schema, REST column or document-version change is needed: both apps already retain `created_at`, and both own version-1 field validation. Saved-view mutations, offline snapshots and exports retain the canonical query. Restore retains recorded creation metadata and maps unrelated project/label identities without changing the creation predicate.

The safe unsupported-query preservation baseline is iOS `c8d96f8` and Mac `362b3ad`. Clients at that baseline or later without these capabilities must retain the complete query, report it unavailable, and refuse editor Save or mode switching. Install creation-date support on both devices before using it across them. Earlier clients need upgrading; this change cannot retroactively repair their behavior. It does not claim full Todoist-language parity.

## Verification scope

The owned fixtures cover syntax/AST round trips, invalid values, unknown timestamps, inclusive day/exclusive before-after boundaries, fractional/offset timestamps, midnight, DST folds, half-hour DST, travel, skipped civil days, leap-year offsets, cache invalidation, queued snapshots, backup restoration and independently expected eight-day widget IDs. Native iOS tests create through the builder, reject timed creation values, save an older-work filter, edit to recent-work syntax, relaunch without reseeding and verify retained query/results in light and dark/large-text modes. The Mac native test covers validation, results and relaunch, subject to the standing Mac runtime restriction.

Current build/test results and missing runtime gates are recorded in each repo's validation/status document. Provisioned installed widgets and actual signed-in iOS/Mac account, offline replay and access changes remain required for the full P0 acceptance.

## Remaining query-language port work

Sliding instant windows, configurable next-week rules, task/project hierarchy, wildcard targets, collaboration/creation-author predicates and ordered comma sections remain open. The creation-date package closes only the creation-date source portion of the hierarchy/creation work package.

Source: [Todoist's filter reference](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH), checked 7 October 2026, documents created/on/before/after, including negative-day examples. Taskfold defines its boundary, legacy-metadata and rollout semantics explicitly above.
