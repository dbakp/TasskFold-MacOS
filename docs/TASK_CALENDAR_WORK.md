# Calendar periods and productive work

26 October 2026. Week, three-day, five-day, month and year views now use the same
productive work projection as day planning. A heading is context; its nearest
ordinary descendants keep their own dates. An ordinary task's checklist is not
counted again. Completed work remains reviewable without increasing open-day
counts or heatmaps.

CalendarWorkReading separates readable counts from actionable rows. A missing
child identity never becomes a guessed editable task. A partial-work notice
explains unreadable branches; dates use the viewed time zone. Each view caches
its index and rebuilds on task changes, project archiving, calendar-day and
time-zone changes. The Mac selected-day list retains explicit checklist expansion
as detail context without increasing scheduled totals. Existing parent breadcrumbs
and platform styles stay in use.

On iOS, child details capture the current hierarchy selection, and completion
uses the existing parent-owned selection plan with baseline/workspace checks.
Mac cards, inspector, completion, Undo and drag/drop retain their existing
hierarchy-aware action paths. No backend data contract or normal heading
configuration changes. Heading authoring remains isolated-test-only.

## Verification

Six new Core scenarios in each repository cover independent child dates and
nested headings, ordinary checklists, completed rows and pending completion,
root-scoped routes, missing identities, time zones crossing a month boundary,
and root-versus-projected duplicate suppression. The selected planner/progress
suite passes: 76 iOS checks and 75 Mac checks (existing suite sizes differ).

Native/build evidence and remaining limits are recorded in calendar-work/.
No hosted migration, release signing or distribution acceptance is claimed.

The corrected native scenario passed on iPhone and iPad, including explicit
Week/Month/Year selection, child details, completion, cold persistence and Reopen.
Mac native runtime remains pending; its app build and owned Core checks pass.
