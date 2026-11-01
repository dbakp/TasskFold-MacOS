# Subtask ordering activity

Project pulse records one **Subtask · Order changed** entry per reordered sibling list. The current parent list, actor and recorded time use the existing presentation. Root-list entries open the root; nested entries open their current parent only within the original task generation and current workspace. A separate coverage date makes the beginning of ordering history explicit.

Only the order of surviving siblings under the same stable parent is compared. Insertion, removal and reparenting do not label shifted peers as reordered. A real reorder combined with insertion/removal still records the common siblings’ relative order. Version 3 retains stable IDs, not titles, notes or other field contents. It is a list event, excluded from completion credit and lifecycle counters. Older version 1/2 records and bytes remain supported.

Each repo owns its client, migration, actual-server fixture and test scripts. The same canonical migration ID avoids duplicate deployment to a shared backend. No normal-use gate, hosted schema, RPC grant or earlier user deferral changes.

## Evidence

- `core.json`: 126 focused cases per client, including exact server rows, nested/root order, insertion/removal/reparenting, mixed changes, guarded current links, Undo/retry/account isolation, coverage, malformed data and unchanged completion credit.
- `postgres.json`: 99 actual local database checks per repo: owner/team editor structure commands and Undo, exact receipt replay, unchanged-slot refusal, insertion/removal/reparenting, transaction rollback, viewer/outsider restrictions, private-content exclusion, strict contexts, closed helper grants and no added advisor findings. Owned fixtures removed.

- Mobile `phase`, `summary`, `proof` and `state` records bind the current signed build to saved/cold iPhone and largest-text/dark iPad displays. Exact caches retain one ordering event, one edit event, the saved sibling order and no pending network work. Selected captures in the iOS repo were visually inspected.
- Both app builds/signatures pass. The Mac app-only build is distinct from runtime acceptance: its launch was attempted, but computer use reported a locked screen. The exact isolated process was then closed.

## Still open

Shared-operation grouping and wider history timing/lifecycle acceptance; older-data/history mapping; shared file/discussion custody; hosted migration and genuine shared-account acceptance. The broader migration remains unfinished and disabled for everyday use.
