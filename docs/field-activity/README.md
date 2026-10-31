# Subtask field edit activity

Project pulse now shows **Subtask · Edited** with a short field-name caption, such as **Notes · Priority**. The actor, current-task link and recorded time use the existing workspace-bound history presentation. Field edit coverage has its own start date; earlier title/note edits are not invented or backfilled.

The existing atomic node ledger compares actual before/after fields. Names are limited to Title, Notes, Priority, Labels, Estimate, Assignee and Reminders. Field values, request bodies, private text and unknown opaque properties are excluded from the public history. A combined edit produces one node event. Real planning/completion changes keep their established kinds and chosen completion time; edit details add no completion credit. Creates and removals remain ordinary v1 events. No-op edits and receipt retries add no fictional event.

Each repo owns its SQL migration, fixture, client and tests. No RPC permission or normal-use migration gate is enabled here. Existing local v1 event bytes are preserved; v2 is used only for the new detail records. The reader accepts only known sorted field names and the matching event algebra, and supports both epoch shapes. The server migration is committed source, not a hosted deployment.

## Evidence

- `core.json` / `core.log`: 116 focused client cases per repo, including unchanged frozen legacy event bytes, strict v2 reading, local Undo/Redo/retry, coverage, account separation and unchanged completion credit.
- `postgres.json`: 73 checks in each independently run owned PostgreSQL fixture. Actual personal/team field RPCs exercise one combined entry, retry, no-op suppression, date-plus-edit, optional-field removal, current permissions, private-content exclusion and rollback of task/node/receipt/history together. Advisors add no findings and the owned containers are removed.
- Each repo's `TaskfoldTests/Fixtures/child-field-activity-v2.json` contains that repo's actual server rows; its strict client reader accepts every row.
- Mobile `phase`, `summary`, `state` and `proof` records bind the built source to real iPhone and iPad journeys. The normal/light and largest-text/dark displays survive a cold return. Persisted caches contain one edit entry, two node events, no pending network mutations and unchanged private task content; exports retain only ledger metadata.
- Selected screenshots are retained in the iOS repo. Mac build/signature evidence is separate from runtime display acceptance, which remains open because the Mac was locked.

## Remaining shared-history work

Parent/sibling ordering, grouping across shared operations and wider timing/lifecycle acceptance remain unfinished. Older-data/history mapping, shared file/discussion custody, hosted deployment and genuine shared-account acceptance remain separate migration work. Ordinary migration use remains disabled, and all user-requested rollout/configuration deferrals remain in force.
