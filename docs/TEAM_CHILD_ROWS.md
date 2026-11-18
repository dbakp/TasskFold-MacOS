# Team subtasks as rows: client contract

Phase T of `design-review/child-tasks-plan.md`. Server side: `supabase/migrations/20261117100000_child_task_rows_team.sql` (Migration T). Tests: `supabase/tests/child_task_rows_team.sql`.

After Migration T, a subtask in a team project is an ordinary `public.tasks` row with `parent_id` (its parent task) and `child_order` (its position among siblings). This is the same model personal and shared projects have used since Migration B. Team tasks stay closed to direct PostgREST writes, so every write goes through the team RPCs below. Reads are unchanged: `select=*` on `tasks` returns the child rows to everyone who can read the project (viewers included).

The structure rules come from `guard_task_parent` and are the same everywhere:

- A subtask stays in its parent's project.
- A root task plus at most 10 levels of subtasks.
- No cycles.
- `child_order` is filled in as max(siblings) + 1 when it is left out.

Every RPC checks the caller's role on the parent's project. Because a subtask always shares its parent's project, the role on the parent is the role on every subtask.

All calls are `POST /rest/v1/rpc/<name>` with the signed-in session, as today. Each body field is unchanged unless it is listed below.

## Error codes added or reused for child rows

| Code | Message (prefix) | Meaning | Client handling |
|---|---|---|---|
| `23503` | `The parent task is not available` | The parent is missing or not readable | Offer "Discard" or "Keep as a separate task" (same as personal) |
| `23514` | `A subtask must stay in the same project as its parent` | Cross-project parent | Fix the request: detach it or move it with its parent |
| `23514` | `A task cannot become a subtask of its own subtask` | Cycle | Reject the indent locally |
| `54000` | `Subtasks can be at most 10 levels deep` | Depth limit | Reject the indent locally |
| `PT409` | `TASKFOLD_CONFLICT: This task was moved under a different parent on another device…` | Three-way `parent_id` conflict on a saved edit | Show the conflict review |
| `PT409` | `TASKFOLD_CONFLICT: Subtasks are now tasks. Update Taskfold to edit them.` | A non-empty JSON `subtasks` was written (the freeze now covers team projects) | Never send a tree |
| `PT409` | `TASKFOLD_CONFLICT: Review the subtasks before deleting` / `…before moving` | A descendant is not team content of this project (corrupt or concurrent state) | Re-sync, then retry |
| `PT409` | `Review the recordings and 30-day restoration period before deleting` | A subtask with published recordings blocks a cascaded delete while recording restoration is on | Delete that subtask on its own first, with its `audio_restoration_ack` |
| `PT409` | `TASKFOLD_CONFLICT: Delete this team task with a supported Taskfold app so its subtasks are removed with it` | Defence in depth (`guard_team_parent_delete`). The RPCs never trigger it | Not expected from the RPCs |
| `42501` / `PT404` / `PT503` | unchanged | Role, availability and feature gates, as for root tasks | unchanged |

## RPCs

### `taskfold_team_task_lifecycle(_action text, _body jsonb) -> jsonb`

Handles `create`, `delete` and `restore`.

**Changed: `record` accepts `parent_id` (uuid or null) and `child_order` (number or null).** Every other record key and body key is unchanged.

**create**

- Send `record.parent_id` to create a subtask.
- `child_order` is optional (default: append).
- The parent must be in `project_id`.
- The caller needs `manager` or `editor` on the project, exactly as for a root task.
- A JSON `record.subtasks` tree is still accepted for compatibility (workflow runs and older builds). The server never stores it. It converts it into child rows with `legacy_child_id(task_id, path)` ids, the same ids as `LegacySubtaskConversion`. New builds should create each subtask with its own `create` call instead.
- **New reply key:** `children`, the live descendants of the task, parents first (an empty array for a new leaf).

**delete**

- `record` must be the full live row: the lifecycle keys, including `parent_id` and `child_order`. Leave out `waiting_on`, and leave out `is_heading` when it is null (as today).
- Deleting a parent deletes all of its descendants in the same transaction, deepest first. Each descendant gets its own certified deletion:
  - restoration hash
  - discussion archive
  - file and recording custody
  - detached repeat links
- **New reply key:** `deleted_children`, an array in parents-first order: `{request_id, task_id, task_generation, parent_id, task}`.
  - `request_id` is the descendant's own deletion identity. It is `md5('taskfold.team-child-delete.v1|' || <parent request_id> || '|' || <task_id>)::uuid`, so a client can recompute it.
  - `task` is the deleted row.
- A replay of the same request returns the same `deleted_children`.

**restore (Undo)**

- Restore the parent first with its own `restore_from`.
- Then restore each entry of `deleted_children`, in the order given, with one `restore` call each:
  - `restore_from` = that entry's `request_id`
  - `task_id` = the entry's `task_id`
  - a fresh `task_generation`
  - `record` = `entry.task` minus `waiting_on` (and minus `is_heading` when it is null), with `task_generation` set to the fresh generation
- The structure, discussions, files and repeat links come back as they were.

### `taskfold_team_task_batch(_operation text, _body jsonb) -> jsonb` (`delete` / `restore`)

- **Changed:** items may include a parent and its subtasks together.
  - `delete` processes subtasks before their parents.
  - `restore` processes parents first. This follows `record.parent_id`, as it already did for `recurrence_parent_id`.
- An item whose subtasks are not in the selection deletes them by cascade, exactly as the single `delete` above. Those cascaded subtasks are not batch members: restore them with single `restore` calls after the batch `restore`, using the `deleted_children` entries the server recorded.
  - The batch reply does not list them yet.
  - Recompute their `request_id` with the formula above.
  - Or prefer sending the whole subtree in the selection, so the batch Undo covers it.
- `edit` (planning batch) is unchanged. Its base comes from `record`, so include `parent_id` and `child_order` there.

### `taskfold_edit_team_task(_body jsonb) -> jsonb`

**Changed: `changes` may contain `parent_id` and/or `child_order`.** Like every edited key, each one needs its value in `base`.

- Indent, outdent, "Make it a task" (`parent_id: null`) and reorder are all saved edits.
- A `parent_id` change conflicts (`PT409`, see the table above) when another device moved the task to a different parent since `base`.
- A `section_id` change on a parent moves all of its descendants to that section in the same transaction.
- `subtasks` is still accepted as a key. A non-empty value now fails with the freeze `PT409`.

### `taskfold_team_task_move(_operation text, _body jsonb) -> jsonb` (`review`, `move`, `review_undo`, `undo`)

**Body unchanged.**

- **Moving a parent** to another team project takes its descendants along. That includes their discussions, files and published recordings.
  - **New review key:** `child_row_count`.
  - `audio_custody_count` and `file_custody_count` now include the descendants.
  - The review token covers the descendants: any subtask edited after the review gives `This task, discussion or project access changed after review`. Review again.
  - Descendants lose their assignee on the project change, like the parent does.
  - `undo` brings the whole subtree back. Cleared assignees are not restored.
- **Moving a subtask** to another project detaches it: it becomes a root (`parent_id = null`, `child_order = null`) in the destination. Its own descendants go with it. `undo` returns it to the source project as a root and does not re-attach it.

### `taskfold_complete_team_task(_action text, _body jsonb) -> jsonb` and `taskfold_complete_team_tasks(_action text, _body jsonb) -> jsonb`

- **Changed:** `record` must include `parent_id` and `child_order`, because the whole record is compared with the live row.
- Completing a parent does not complete its subtasks on the server (decision 1). The client completes the open descendants in the same user action, preferably in one `taskfold_complete_team_tasks` batch, so it is one Undo step. Reopening a subtask under a completed parent reopens its ancestors on the client (decision 2).
- **Recurring parent:** completing it creates the next occurrence together with fresh, open copies of its subtasks. Their dates move by the same number of days as the parent's due date.
  - Copy ids: `md5('taskfold.team-successor-child.v1|' || <successor id> || '|' || <source subtask id>)::uuid`.
  - `undo` removes the occurrence and these copies only while none of the copies was touched (no completion, edit, discussion, file or repeat link). Otherwise the occurrence is kept, as it already is when it has a discussion.

### `taskfold_team_workflow_run(_body jsonb) -> jsonb` and team templates

Unchanged. Template documents keep nested `subtasks`, and `tasks[i].subtasks` is sent exactly as today. The server creates each task through the lifecycle RPC, so every nested subtask becomes a child row with `legacy_child_id(<task id>, path)` ids.

- The reply lists only the top-level tasks.
- Read the child rows back with a sync or `select=*&parent_id=eq.<id>`.

### `taskfold_copy_team_draft(_body jsonb, _commit boolean, _cancel boolean) -> jsonb`

Unchanged for clients. A JSON tree inside a saved draft becomes child rows under the copy.

### Personal and shared projects (unchanged since B, listed for completeness)

- `taskfold_patch_task(_id, _base, _changes)` accepts `parent_id`, `child_order` and `waiting_on`.
- `taskfold_delete_task(_id, _base)` compares the full baseline, `parent_id` and `child_order` included.
- Direct `POST /rest/v1/tasks` creates subtasks there.

## Before C

**Status (app PR `team-child-rows-apps`):** every item below is cleared in both apps. Team subtasks are child rows through the team RPCs, the team JSON checklist path is deleted, no task write sends `subtasks` (rows cached before C lose an empty value on load, and outbound changes drop it), backup restore turns v1/v2 JSON subtasks into rows client-side, `taskfold_move_personal_task` is no longer called, and the UI-test fixture no longer stubs the dropped RPCs. Install builds from that PR on every device before deploying C.

`supabase/migrations/20261117110000_child_task_rows_c.sql` (Migration C) drops `public.tasks.subtasks`, the 34 legacy child RPCs, the `taskfold_private.child_*` tables and the legacy triggers. **Do not deploy C until a build without the items below is installed on every device.** The inventory below is from `origin/main` of both repos (iOS 48ed6156, Mac 8dc8935a).

### 1. Hard failures after C (PostgREST rejects the unknown column, or the RPC rejects the key)

| What | Where (both repos unless noted) | After C |
|---|---|---|
| New task records carry `"subtasks": []` and are POSTed to `/rest/v1/tasks` | `Taskfold/Core/Models.swift:201` (`Record.task(...)`). Any POST that copies a synced row (it has no `subtasks` after C, but cached rows from before C do) | `PGRST204 Could not find the 'subtasks' column`. **Every task creation fails.** |
| Backup restore inserts the `tasks` column allowlist, which includes `subtasks` | `Taskfold/Core/Backups.swift:96` (`columns["tasks"]`), `:177`, `:922` (template fields), `:260-265`, `:465`, `:497-500` (PATCHes `subtasks` for assignments) | Restore POSTs and PATCHes fail (PGRST204 / unknown key) |
| Team completion `record` includes `subtasks` | `Core/TeamCompletion.swift` (`record` is the cached task row; rows cached before C still carry `subtasks: []`), `Core/TeamCompletionDraft.swift` | `22023 Include the original task and completion revision`, because the record keys must be real columns |
| Saved-draft copy `record` / `original.record` include `subtasks` | `Core/TeamCompletionDraft.swift` | `22023 Use fresh task and action identities` |
| Team checklist edits send `changes.subtasks` (non-empty) | `Core/TeamChecklist.swift`, `Core/Models.swift:1572` (team PATCH scope) | `PT409` freeze (already since T) |

### 2. Tolerated after C, but should go (sent or read, ignored by the server)

| What | Where | After C |
|---|---|---|
| `taskfold_patch_task` with `subtasks` in `_base`/`_changes` | `Core/Models.swift` merge fields (`:494`, `:506`, `:661`, `:821`), assignment clearing (`:2324`, `:2366-2374`) | An empty tree is ignored. A non-empty one fails with the freeze `PT409` |
| `taskfold_delete_task` baselines with `subtasks` | full-row baselines from the cache | An empty `subtasks` is ignored |
| Team lifecycle / batch `record.subtasks` | `Core/TeamWorkspace.swift`, `Core/TeamTaskMove.swift`, `Core/TeamTaskLabels.swift`, `Core/TeamProjectAccess.swift` | Accepted. A tree becomes rows, never stored |
| Workflow run `tasks[i].subtasks` | `Core/TeamWorkflowRunCommands.swift`, `Core/ProjectWorkflows.swift` | Accepted. Template trees become rows (keep sending them) |
| Reading `task["subtasks"]` from synced rows | `Core/Filters.swift:489-490,720`, `Core/SubtaskTree.swift`, `Core/TaskActivity.swift`, `Core/SpotlightIndexing.swift`, `Core/PrintDocument.swift`, `Core/TaskBreakdown.swift`, `Core/WidgetCompletion.swift`, `Core/ChildRowSatellites.swift`, Views (`TaskEditor`, `TaskInspector`, `SubtaskOrganizer`, `CollaborationViews` / Mac `Collaboration.swift`, `TeamTaskMoveView`, `TeamProjectAdoptionView`, `TeamWorkflowRunView`, `PlanDayView`, `SavedViews`, `PrintReviewView`, `BackupTools`) | The key is absent (reads `.null`). Harmless once the legacy UI is gone |
| Local conversion helpers | `Core/LegacySubtaskConversion.swift`, `Core/ChildRowSatellites.swift:164-169`, `Views/ChildRowsCutover.swift`, `ChildRowsFixture.swift` (iOS) | Local only. Keep for old local data and backups v1/v2 |

### 3. RPCs that C drops

- None of the 34 legacy child RPCs that Migration B revoked are called by the app code on `main`. Only the UI-test fixture `Taskfold/TeamTemplateNativeFixture.swift` stubs `taskfold_restore_child_original` and `taskfold_repair_children` by URL. Retire those stubs with C.
- `taskfold_move_personal_task` stays, but it has answered `PT503 Separate subtask project moves are not enabled` since Migration B switched the JSON child-record flags off, and C keeps that.
  - Builds still call it when `Mutation.personalTaskMove == true`: `Core/Backend.swift:575, 1170, 1180` (iOS) and `:559, 1154, 1164` (Mac).
  - Child rows move with a plain project PATCH, and the server cascades the move.
  - Stop setting `personalTaskMove` for child-row tasks.

### 4. Server-side follow-ups already in C

- C strips `subtasks` from every function that stays.
- The Todoist import no longer emits `subtasks: []` (this PR).
- The automation API has rejected non-empty `subtasks` since B. After C, SQL callers get `22023 Subtasks are tasks: create each one with parent_id`.
