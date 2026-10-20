# Project organization and reusable workflows

Implemented in the independently owned iOS and Mac apps. The three user-deferred rollout items—remote reminders, older-client safeguards and distribution verification—remain outside this work.

## Organize projects

Edit a project to choose its **Parent project** or mark it **Archived**. Project lists display the hierarchy, with up to 20 levels. Each project keeps its own task list; moving a project does not move its tasks into a different project or change sharing. Only the owner can reparent, archive or restore it. Cycles, unavailable/foreign-owned parents and moves that make a whole subtree too deep are rejected locally and by the database.

Archiving a parent hides its descendants from active project lists, global daily/task queries, widget content, new Focus task choices and local task reminders. It preserves task text, dates, completion, notes, files, assignments, project structure and saved preferences. Existing Focus sessions remain recoverable. Explicit project views and whole-workspace search still allow access to saved work; favorites and note pins are retained rather than deleted.

**Archived projects** opens the archive browser. Restore a parent to reactivate inherited children. A child that was independently archived remains archived until separately restored. An inherited child can also be moved to the top level. Deleting a project uses the existing confirmation: direct tasks move to Inbox and subprojects are promoted without deleting their tasks.

Archive browser task counts are per project, so a parent with no direct tasks can show zero while its child shows its own saved tasks.

## Save and use templates

Open **Templates** from Browse on iOS or the Mac sidebar.

1. Choose a project and its descendants, one section, or one task.
2. Give the private template a name and save it. Archived sources remain available.
3. Select the template, choose a new project name or destination, and optionally choose a start date.
4. Review its task titles and create the workflow.

Project templates create a fresh project tree and sections. Section templates create a fresh section in the chosen existing project. Task templates create a new task in Inbox or the chosen project. Notes, estimates, priorities, labels, subtasks, supported recurrence rules, sibling order and manual task order are retained. The app's normal priority bands still apply. Available label names are reused case-insensitively or created once for the new run.

Every run has new record IDs and task generations. Completion/history, discussion, attachments, old reminder receipts, provider mappings and assignments are not copied. The original work is never reset. Task/project creation and template actions participate in Undo; Mac actions also use the native Edit menu.

Scheduling is relative to the earliest planned date, otherwise the earliest deadline. A chosen start day rebases existing planned dates, deadlines and recurrence bounds; originally undated tasks remain undated. Without a start day the new tasks have no planned dates or deadlines, and old recurrence date bounds are cleared.

Templates sync privately to the same account and travel in workspace backups. Deleting a template removes only its reusable definition. Newer, unsupported template formats remain saved and survive backup/restore; the current app refuses to apply them. This version saves, uses and deletes definitions; there is no template marketplace or standalone template-file interchange.

## Add multiple tasks

Open **Add multiple tasks** from Browse/sidebar or the task-list tools. iOS quick capture also offers it and sends multi-line submissions to review. The Mac task-list capture routes multi-line submissions to the same review.

Paste up to 200 nonblank lines or 100 KB. Checklist bullets, numbered-list prefixes and checkbox markers are removed. Choose Inbox or a project, and choose whether to recognize dates, priorities, labels and supported quick-entry references. Review every resulting title, destination, date and warning. Edit titles or exclude lines before saving; returning to the original text rebuilds the preview.

One save writes the selected tasks, any new labels and order rows together in the device's atomic snapshot. One Undo reverses the batch. Failed saves retain the preview and pending identities for retry. Workspace changes or missing/archived destinations require review again. Cloud transport uses the existing durable per-record queue; it is not a new server-wide graph transaction.

## Data and verification

- `ProjectWorkflows.swift` owns cycle/depth/archive rules, pure line parsing and versioned template capture/instantiation.
- `projects.parent_id`, `is_archived` and derived `ancestor_archived` retain archive visibility for a collaborator whose parent project is not shared. Sharing never inherits down the hierarchy.
- `project_templates` has explicit grants, owner-only row-level security and realtime publication. Its private trigger functions use fixed search paths and security-invoker execution.
- Migration `20261020174132_project_workflow_foundation.sql` is the CLI-created migration aligned to the actual MCP-applied server version. Both repositories contain identical SQL.
- Portable restore remaps project parents and template row identities, orders parents first and preserves opaque future template documents. Malformed own-project references and cycles fail before writes. A shared child whose parent was not visible to the exporter is copied to the top level with an explicit warning and its effective archive state retained.
- `ProjectWorkflowsTests` covers archive inheritance/restoration, unavailable ancestors, graph safety/depth, owner boundaries, parser/literal/size limits, fresh/retry IDs, history exclusion, recurrence rebasing, ordering, portable restore, future documents and old widget actions after archiving.
- `supabase/tests/project_workflows.sql` exercises actual owner/member/outsider roles inside a rollback transaction, including hidden-ancestor projection, ordinary member edits, owner-only organization, template privacy, 20-level bounds and parent deletion. No test accounts remain afterward.

The database advisory comparison adds the expected [authenticated schema-visibility notice](https://supabase.com/docs/guides/database/database-linter?lint=0027_pg_graphql_authenticated_table_exposed) for the new API table; actual row privacy is tested with owner/member/outsider roles. Prior advisories are unchanged.

See `project-workflows-evidence.json` for the final build/runtime results and their limits. Prior P0 results are not counted as acceptance for these new screens.

## Reproduce isolated UI checks

Each repository owns `Scripts/prepare_workflow_ui_test.py`; it copies only that repository. Run it with a new output folder. Mac outputs must be under `/private/tmp` or `/tmp`. A namespace beginning with `workflowtests` is required, so production identifiers are rejected.

Use consistent Apple Development signing from the first Mac test build. Use a fresh namespace when changing signing identities; do not delete or weaken an existing sandbox. Build iOS UI-test products with signing enabled, even for Simulator. Run only the named project-workflow UI tests against the disposable app. Start independent fixture scenarios from a fresh disposable installation; preserve the installation within each test when checking relaunch/retry. Never reset the production app. The fixtures require Debug, `--uitesting` and `--workflow-fixture`; they do not use real accounts. The iOS test additionally exercises an injected persistence failure/retry through the existing debug persistence fault hook.

Mac's `--workflow-diagnostics` can log the synthetic snapshot only in an isolated workflow namespace with `--uitesting`. It is unavailable to production account/bundle identities. It avoids direct reads of another app's protected container during native verification.

## Deferred acceptance

Remote-delivery eligibility must respect archived projects before remote reminders are enabled. Older clients can still bypass newer editing safeguards and do not provide this archive UX; that rollout work remains explicitly deferred. Signing/distribution/install/update acceptance is also deferred. Passing these feature checks does not clear those release gates or claim a new native cloud handoff for this feature set.
