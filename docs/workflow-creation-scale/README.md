# Workflow creation and widget publication

The supported structured definition can contain 5,000 tasks, 5,000 sections and
5,000 labels, producing 20,001 queued records. Earlier source kept Undo but
performed repeated list publication, record scans and full widget membership
scans while saving. The retained native baseline creates 1,000 tasks, saves all
4,001 commands and one Undo, but advances taskRevision 1,000 times. The red test
asserts the desired single advance; its only failure is that counter.

The Store now reuses the immutable normalization lookup/catalog, validates every
row, and projects wholly fresh, owned, unique insert-only workflow identities
into a local Snapshot. A consumed append plan cannot append an identity twice.
Collisions, retries, mixed commands and shared commands retain ordinary replay.
The task list is refreshed once after history/size admission, before persistence
and widget publication. Failed persistence restores the original presentation.
Generation/type/heading checks, activity recording and atomic Undo remain in use.
Insert-only list orders skip a recovery operation that already rejects that type.

TaskCache lazily indexes project presentation/outline and raw string label
positions. Alias unions keep source positions and duplicates by position, rather
than inventing identity deduplication. Source changes discard the indexes.
Hierarchy-filter candidates keep their existing path. Widget publication indexes
account-owned preference/order rows with the same first-match behavior and groups
sections and task rows once. No task/list/group quota or omission was added.

Core acceptance includes full structured append/queue/Undo/cold encoding, direct
projection parity and collision refusal, exact label alias/order/cache refresh,
and publishing/decoding/writing every task, list and group in the full widget
payload. Existing hierarchy, productive work, filters, calendars, assignment,
manual ordering and widget behavior are included in the selected suite.

Native scale tests call the real Store in a signed isolated host. They verify the
saved cache, exact record/queue counts, one Undo and one taskRevision advance.
Remote delivery is deliberately paused for this exact DEBUG measurement mode;
these timings include local projection, encoding, save and widget publication,
not hosted delivery or an end-to-end 5,000-task production screen benchmark.
Each measurement has a unique proof/file so an old receipt cannot pass a later
case. A guarded fixture action restores the original saved snapshot before the
next case. The normal client cannot enter this fixture mode.

The first batching attempt still took minutes for the full case. Sampling found
Snapshot.apply scans, then WidgetProjection.listPayload repeated membership
work. That version was not accepted as responsive. Its metrics and bounded
samples are retained separately. Superseded test runs were stopped for these
verified problems, not restarted because an observation timed out.

Mac UI Automation was enabled following the user's approval. Initial runtime
checks exposed fixture issues: its App Group entitlement was absent in this isolated host; an unrelated Settings error observer was active outside the visible fixture; and a runner's
best-effort receipt deletion could leave old data. The DEBUG host now uses its
private widget directory, its visible error presenter and isolated Settings
content. Unique receipts need no runner writes to the app container. Release
settings, entitlements and normal app settings behavior are unchanged.

Final evidence must distinguish installed native cases, Core full-data checks
and remaining work. Local activity-history scaling, rendering full production
screens, background save/archive I/O and real/paired bulk delivery remain open.
The wider ranked Px backlog and user-deferred rollout, release, provider,
server-reminder and older-client work remain active/deferred as before.

Final coverage has ten unique passing methods on each of three platforms,
assembled from the main matrix plus specific warning-selector/inline-error
reruns. iPhone/iPad each have nine main passes plus the retry pass; Mac has seven
main passes, two Cocoa warning passes and the retry pass. No failed result is
renamed a pass. The app behavior did not change during those test-only fixes.
The retry also verifies that the sheet closes and the real list row is hittable.
