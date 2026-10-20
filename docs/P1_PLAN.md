# P1 implementation order

User-directed scope, 20 October 2026. Ranking favors daily usefulness and preservation of existing work, then independent features, then provider/team dependencies. Both apps own their implementation and tests. Remote reminders, older-client rollout and distribution remain deferred.

| Rank | Work | Why this order | Acceptance |
| --- | --- | --- | --- |
| 1 | Nested subtask editing and organization | Existing work can contain children that the primary editors do not expose. This is a daily editing gap. | Both apps can edit/complete nested children, including notes and planning fields on both apps, add children, reorder whole branches and indent/outdent; Cancel preserves work; Save/relaunch retains metadata and stable identities; concurrent moves/edits do not duplicate children or discard their notes. |
| 2 | Saved template management | Builds directly on the newly implemented reusable workflows. | Rename/edit saved definitions, refresh from a source with review, preserve existing runs, reject unsupported versions and verify cross-device edits. Standalone interchange and a public catalog are later additions. |
| 3 | Widget manual/grouped ordering | Makes the desktop/Home Screen reflect how the user arranged the app. | My list respects supported saved ordering/grouping; additions/completions/retries retain identity and honest empty states. |
| 4 | Useful Insights and daily/weekly goals | Existing activity recording supports factual progress without invented history. | Explicit scope/time window, completion-occurrence deduplication, reopen correction, rest days and coverage-boundary messaging; matching settings/results across apps. |
| 5 | Advanced recurrence | Extends daily scheduling once organization is usable. | Multiple monthly dates with clear preview and consistent month-end/zone/count behavior; persistence, completion/Undo and cross-device fixtures. Sub-day/holiday policies require their own explicit design. |
| 6 | Direct Google/Outlook calendar connections | Useful but requires provider OAuth/reconnect and real-account acceptance. | Read-only calendars first, visible provider/account, private event handling, selected calendars and disconnect/reconnect; mirroring only after identity/deletion/loop policy and acceptance. |
| 7 | Shared activity and mentions | Depends on clear ownership, access and notification semantics. | Project-scoped activity, permission-checked mentions, departed-member safety and honest local/remote delivery state. Advanced team roles/folders/admin remain separate. |

Already delivered: archive/restore, owner-safe subprojects, first-version private templates, reviewed multi-line capture, native assignment/member controls, guarded collection edits and the Project pulse history foundation. These are not new implementation backlog entries.

## First implementation: subtask organizer

Status: **Rank 1 is delivered for the embedded checklist model:** nested organization and child-detail editing (including notes and planning fields) are implemented in both apps. Representative native phone/tablet/Mac checks and both owned core suites pass. The organizer’s prior live transport acceptance remains recorded separately. **Next: rank 2, saved template management.**

- A dedicated Organize subtasks sheet exposes the nested checklist while retaining existing inline controls.
- Each row has an editable name, completion state and actions for adding a child, sibling moves, indent/outdent and confirmed branch deletion.
- The sheet holds an isolated draft until Save; Cancel does not assign legacy identities or change saved work. A task/workspace change refuses the stale draft.
- Branches retain IDs and all existing fields, including unknown metadata. Missing legacy IDs are assigned in the explicit saved draft; malformed/duplicate identities are refused without rewriting the original.
- New nesting is bounded to ten levels, including the containing inspector depth on Mac. Existing deeper supported data stays readable.
- Current guarded transport remains in use. The collection rebase indexes identities across the tree so a moved child retains remote field changes and is not duplicated at its old location. A reviewed local layout retains remote-only children. This is not the deferred migration to independent child-task database records.
- No new task/child tables or sibling build dependency are introduced. A compatible guarded-RPC migration is included.

The list/planner progress badges count all supported checklist levels. Native iPhone/iPad checks cover Cancel, whole-branch moves, completion, composer preservation, task Save, relaunch and the 1-of-5 count. Mac additionally covers native Undo/Redo, child creation/deletion and normal app-menu Quit/relaunch. Both independently compiled cores pass real-service two-client move/order conflict/review/retry tests. See `p1-subtasks-evidence.json` and `p1-subtasks-database-evidence.json` for exact coverage and limits.

Migration `20261020194217_subtask_structure_review.sql` fixes an observed service acknowledgement that silently retained the old array order after a concurrent append. It requires review when either client changed checklist structure, while retaining automatic merges for independent fields with unchanged structure. The role fixture checks owner behavior and outsider denial. The helper is private, security-invoker, has a fixed search path and grants no execution to anon; security advisors add no warning. The CLI-generated filename is aligned with the actual remote migration version in both repos.

This organizer is a draft until Save; iOS then returns to the outer task editor, whose Save retains the task. Mac applies it through the existing task autosave/Undo path. It does not move rows outside the task being organized or migrate embedded children to independent database records.

### Reproduce the first foundation checks

Use each repo's `Scripts/prepare_workflow_ui_test.py` with a fresh `workflowtests` namespace. The synthetic fixture additionally requires `--uitesting --workflow-fixture --subtask-organizer-fixture -localMode YES`. Run iOS UI test `testSubtaskOrganizerCancelMoveSaveAndRelaunch` on phone and tablet sequentially to avoid shared keyboard-focus ambiguity. Mac normal relaunch retains `--uitesting -localMode YES` but omits both reset fixture flags. Keep consistent development signing for the Mac namespace and use a fresh physical bundle path when Launch Services has cached an older bundle at the build-product path.

Core suites include `SubtaskTreeTests`; the optional live test uses `TASKFOLD_SUBTASK_LIVE_FIXTURE` with a private JSON file containing the URL/public key and a fresh synthetic continuity-account ID/email/password. Never supply a real account. `SubtaskTransportIntegrationTests` creates only its own task, exercises two sessions, and removes that task. Revoke sessions, delete the disposable account and remove credentials after the run. The actual-role SQL fixture is rollback-only.


### Child-detail editing continuation

The organizer now exposes full child details. iOS opens a child editor that saves into the organizer draft; cancelling the organizer discards those edits, and the outer task Save remains the persistence boundary. Mac labels the action “Save and open details” and saves through its normal inspector/Undo path before navigating. Children inherit their parent’s project; independent project/section movement and pinning are not offered. Existing labels, assignment, comments and attachments remain editable in the established details UI. Repeating schedules and notifications remain parent-task controls; imported child recurrence/reminder metadata is preserved rather than advertised as independently scheduled.

Child edits preserve identities, ownership, provider fields and opaque metadata, update only changed editable fields, and normalize planning dates/instants. A notes-only edit preserves a selected DST-fold instant. The iOS outer editor retains its original guarded save baseline. Local replay merges stale child-array drafts into the latest observed snapshot while keeping the queued network intent/baseline unchanged.

Mac’s previous two-level reference, expansion and assigned-list traversal limits are removed. New branches retain the ten-level creation bound; existing supported branches remain readable to the same 32-level bound as the organizer. List indentation is visually capped to keep the title usable. A native regression initially reproduced an empty inspector for a third-level child, and the fixed build opened and saved that child. Pure reference tests cover every supported level.


Child-detail acceptance: both owned core suites pass (iOS 715 reported, 8 environment skips; Mac 739 reported, 28 skips; zero failures, 19 focused subtask cases each). The same native iOS case passes on iPhone and iPad, verifying child-draft cancellation, notes/estimate editing, outer task Save and relaunch. Mac verifies inherited context, notes/estimate/deadline/priority, a third-level child and normal Quit/relaunch with exact saved-snapshot equality. See `p1-child-details-evidence.json` for precise coverage and limitations. No distribution, remote-reminder or older-client release gate is closed by this P1 acceptance.


## Rank 2 — saved template management

Implemented in both repos; iPhone/iPad native acceptance and live two-client checks pass. The Mac walkthrough remains pending manual unlock, with no runtime acceptance claim. Both apps own a definition editor for template names, project/section names, task and subtask names/notes/priorities/estimates, main-task destinations, sibling order, additions, branch deletion and relative planned/deadline offsets. The editor keeps a draft until Save. Existing runs are independent records and are never updated when a definition changes. Task-level templates retain one main task.

Replace from a source captures a current project, section or task of the same kind and presents both definitions, including structure, notes, labels, repeat metadata and schedule details. Accepting that preview changes only the draft; Cancel still keeps the saved definition. A changed saved template can be compared with the draft before choosing which to keep. A removed template can be saved as a new identity. Unsupported newer definitions are preserved and cannot be overwritten by an older definition during sync review.

The shared transport contract uses the owner-only, security-invoker `taskfold_edit_template` function. Independent name and document changes merge; a definition is atomic and overlapping document edits require explicit review. Deletions guard both name and definition; retries are idempotent. Queued drafts survive remote absence and account-bound persistence, with a fresh ID on explicit recovery. This does not close the deferred older-client rollout gate.

Migrations `20261020204903_template_edit_review.sql` and `20261020205307_template_review_error_response.sql` match deployed history. Actual-role rollback tests cover independent changes, overlapping edits, review/retry, stale deletion, removal, owner isolation and anonymous denial. Live two-client tests initially exposed conflict-response timeouts with SQLSTATE 40001; the follow-up uses the existing task-edit convention (application error P0001), after which both clients pass review/retry/recovery. No assumption about the gateway’s internal retry behavior is required for that observation. Security advisors add no finding. The disposable account, sessions, refresh tokens and test records were removed.

Interchange/public catalogs remain later additions. Full native acceptance is recorded in `p1-template-management-evidence.json`; it must not be inferred from compilation or the core tests alone.

Template acceptance: both owned core suites pass (iOS 731 reported, 9 environment skips; Mac 755 reported, 29 skips; zero failures). Full iPhone/iPad flows verify draft Cancel, exact definition Save, relaunch, later reuse and cancelled source replacement. Saved caches contain exactly one edited template, three independent tasks, six projects and no pending changes; the source and earlier run retain their original notes. Native comparison screenshots were reviewed. Mac independently builds and signs; its interactive walkthrough remains pending manual unlock. Next implementation: rank 3, widget ordering/grouping.
