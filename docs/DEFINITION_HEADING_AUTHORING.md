# Heading authoring in reusable definitions

Both independently owned apps now separate creating a reusable definition from
creating live tasks. The existing heading client opt-in allows mapped CSV heading
rows and template task/heading choices in a signed-in private workspace. It does
not grant personal or shared live-task creation permission.

CSV intake still requires explicit columns/type values, a complete contents
review and a separate Add to templates. It preserves literal titles, ignores
completion/assignment/history fields, retains the original source, and saves only
one account-owned definition. Mapping Cancel creates nothing. Ordinary mapping
remains available when the client cannot author headings; heading interpretation
is refused with an explicit version message rather than silently creating tasks.

The template detail editor now offers Task / Heading on root and nested items.
A child Save changes only the enclosing draft. Parent Cancel discards that draft;
parent Save uses the existing owner/CAS/private queue. Existing runs keep their
saved tasks. The first introduced heading promotes a valid v1 document to v2 with
exact `task_headings` capability. Returning a heading to Task retains v2 rather
than discarding format/type metadata. Identity, children, notes, labels and
relative scheduling are retained. An item captured before its draft position or
contents changed is refused instead of editing the new item at that path.

When the client cannot author new heading types, type choices are disabled, while
editing an existing heading’s title/notes preserves its type and full definition.
Live personal task/workflow authoring keeps its separate existing guard. Shared
runs retain their own fresh actor/access/destination/capability checks.

The private storage contract and existing `taskfold_edit_template` function already
accept bounded opaque versioned documents; no new hosted migration is needed.
The isolated actual-role SQL fixture verifies owned v2 insert/edit/retry, independent
name edits, overlapping-edit refusal, account isolation, unknown future-definition
preservation, and unchanged existing live task/children while live shared heading
authoring remains disabled. Its invoker insert helper is fixture-only and is dropped
before advisors; no public helper or new grant is added to the app migrations.

Verification records are in `definition-heading-authoring/`. Native scenarios use
only the reserved signed debug host, a synthetic signed-in account and local
URLProtocol peer. They verify native entry, account-bound durable queue/cache and
cold return; actual SQL acceptance is independent. Full hosted transport, provider
file delivery, wider concurrency/spoken/largest-text and cross-device acceptance
remain separate. No normal client or hosted rollout setting changed; all user-
deferred provider, reminder, upgrade and distribution work remains deferred.

## Acceptance result

Each repo passes 107 focused Core cases and 23 real authenticated-role isolated
PostgreSQL checks. All five installed native scenarios pass separately on Mac,
iPhone Simulator and iPad Simulator: CSV review/cancel/save/cold return, root
type draft/cancel/save/cold return, nested type editing, actual client-disabled
ordinary CSV mapping/cancel, and disabled-client preservation of existing types.
Mac uses `mac-initial` (nested), `mac-retry` (two enabled scenarios), and `mac-off`
(two disabled scenarios). iPhone uses `phone` plus `phone-off`. iPad uses
`tablet` (root/nested), `tablet-csv`, `tablet-off` (existing type) and
`tablet-off-visible` (ordinary CSV/cancel). Each summary retains its own totals;
failed attempts are retained and are not counted as passes. Seven native images
were visually inspected for the reviewed preview, heading labels and editors.

Initial mobile diagnostic collection stalled after the cases had ended and no
runner remained; those exact owned collectors were explicitly cancelled. Later
runs disabled verbose diagnostic collection. Initial selector, private fixture
entry and iPad sheet-scroll failures were test-harness issues. The final iPad
helper requires the target row center to be below the sheet title bar rather
than trusting a misleading hittable result. It then opens the native menu,
reviews ordinary mapping, cancels and verifies saved task preservation.

These results close this definition-authoring slice, not the entire advanced
backlog. Live personal cloud heading creation, broader source/access races,
file-provider handoff, spoken/largest-text and cross-device acceptance remain
separate. Release signing and the user's other deferred work remain deferred.

After terminal test results and evidence retention, removed 2.27 GB of owned
temporary builds/results and both isolated Simulator app/runner installations.
No Taskfold app process remains. Repository build caches are preserved; see
`definition-heading-authoring/cleanup.json`.
