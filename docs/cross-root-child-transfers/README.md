# Cross-root subtask transfer service and history — 30 October 2026

**Disabled local candidate; the native move feature remains unfinished.** Each app owns its migration, implementation, tests and evidence. Nothing was deployed or enabled for ordinary use.

## Implemented and verified scope

- An identity-addressed transfer moves a branch and its nested work between two different tasks in one transaction. Personal projects/Inbox and same-team tasks are supported by this candidate; crossing workspace realms is refused pending a custody review.
- Both current roots, generations, projects, hierarchy revisions, source incarnation, full branch versions and destination parent are verified. Sorted nonblocking root locks avoid opposite-direction waits. Live actor, access, recipient and rollout checks remain in force.
- Sparse/null containers, raw Unicode IDs, opaque fields, incarnations and completion epochs survive. Cross-project assignment clearing and certified Undo preserve original assignment shape and use existing recipient guards. Moving a branch advances all editable-field revisions, including missing fields, to fence stale requests after an A → B → A return.
- Send/check/close use immutable actor-bound metadata receipts. Exact retries cannot reapply an old move. An unsent close fences delayed Send. Nonces are fenced reciprocally against older field/completion/structure/team/personal-move writers. Late receipt failure rolls back both task trees, actual records and history.
- One-use Undo requires the original exact two-root placement and unchanged moved-branch digest. It restores the original container form and refuses to overwrite newer work. Private deletion archives are never relocated by this operation.
- Server-captured source/destination history links contain identity/planning metadata only. Both clients carry **observed** productive completion credit across a transfer and remove it on a later reopen. Missing source history never manufactures credit. The original completion date, project and actor are retained. Transfers display as moves; project totals do not count incoming transfers as new tasks.

## Evidence

- **615 actual PostgreSQL checks per repo:** transfer 77, personal moves 75, record authority 96, structural commands 221, reviewed team moves 90, project adoption 56. Every regression phase loads the exact new candidate; hashes are recorded. Every owned container was removed; official advisors add no findings over the baseline.
- **521 selected Core checks**, including 14 new history/parser/Insights/backup cases. Each app compiles its own history fixture from its own final database run. The fixture contains real synthetic completion → transfer → reopen events; it is not a constructed claim of an HTTP or UI journey.
- Current isolated app and test builds pass, and development signatures verify. The built history source matches this repo. No new native/spoken/largest-text/runtime acceptance is claimed.
- `verification.json` binds owned sources, fixture and built source hashes. Phase JSON and compressed logs retain actual results. `earlier-phases.json` records failed fixture/code iterations separately; their checks are not added to final totals.

## Still required

Typed transfer commands and two-root durable recovery, destination/review/Undo controls, full discussion/provider/Storage custody, cross-workspace adapters, older-data tools, workload limits and broader native/lifecycle/accessibility acceptance remain. Existing user deferrals remain unchanged. The broad migration checkpoint stays **To build**.

The canonical migration files were created with the CLI. Direct isolated PostgreSQL verification does not prove deployment or migration-history parity: the full local Supabase stack is unavailable (`local-history-unavailable.log`). No hosted migration, real account/task change, provider write or new Simulator was used.
