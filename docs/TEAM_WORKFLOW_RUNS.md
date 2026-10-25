# Shared workflow runs

The intended experience is an explicit destination and audience choice, a complete
workflow preview, then one Create action. Cancel creates nothing. A successful
run creates the full selected workflow together and leaves the reusable source
and existing runs unchanged.

## Implemented foundation

`TeamWorkflowRunPlan` freezes the source, destination, workspace/session and new
content. Personal sources must belong to the opening account; shared sources
keep their full catalog scope and revision. Task/section templates target an
existing scoped project. Project templates create a new team hierarchy with
explicit visibility. Dates, order and portable label names are retained, and
history/assignment/attachments are excluded as in personal template runs. Root
and checklist identities are fresh per run and stable for the same frozen run.
Content cannot be submitted by this value: it exposes no personal-writer mutation
or transport call. Its role checks are preview admission, not server authority.

## Implemented atomic service (source only)

`public.taskfold_team_workflow_run(_body jsonb)` is guarded by the existing team
and native-project gates plus a new default-off private workflow-run gate. It
accepts frozen reviewed rows, not executable template documents. A supported v1
source is verified as provenance and for stale-review detection; it grants no
permission in the destination. Private sources require ownership; shared sources
require current full membership and exact document/revision. All task/project
writes use existing private controllers inside the same transaction. Checked
section/hierarchy writes hold a private transaction scope; direct grants remain
closed. Auth/session locks precede sorted source/destination team locks.

The envelope contains team_id, request_id, team_revision, source, destination,
projects, sections, tasks and orders. Source includes kind, id, nullable team_id/
revision and document. Destination includes mode, nullable project_id/revision,
visibility, folder_id and parent_id/parent_revision. New project rows form one
parent-first branch; task/section templates append into an existing editable
project. Orders include project_id, nullable section_id, exact base_ids and the
new task_ids in reviewed order. Old order is compared under lock and in the
conditional upsert, including an initially missing order row.

Fresh identities are checked before nested-controller calls, so a separately
created task/project or its old receipt cannot become a new full workflow run.
The private receipt holds a HMAC and identity metadata, not workflow text. Exact
replay rechecks current rights, then acknowledges the original result without
reapplying content or order. A late failure rolls back the whole branch, nested
receipts, quota and order together. Runs have bounded source/row/envelope sizes
and count against the existing team daily operation quota (up to 2,000 changed
projects/sections/tasks in one admitted run).

The Swift plan now freezes folder/parent and complete existing actor order into
the same request shape. Shared checklist children use the established checklist
wire fields and fresh tokens. Repeating checklist definitions are preserved but
refused for shared use until that shared format supports their repeat semantics.
This is a compatibility refusal, not silent removal of the rule.

93 isolated SQL checks pass independently in each repo, including the actual
Swift-generated workflow envelope. Both Core suites pass 105 cases; both app
Debug builds compile. These are local synthetic tests, not hosted HTTP or native
save acceptance. No hosted migration/configuration or rollout changed.

## Required next implementation

1. Use one durable account/origin-bound request and receipt for the entire run.
   Freeze rows, dates, identifiers and destination ordering before sending;
   lost replies/relaunch retry the same request. Match receipt identities and
   source/destination context exactly. Recheck current access for receipt replay.
   Conflicts require a fresh explicit review; no partial retry or silent rebase.
2. Build native destination/content reviews in each app. Support audience and
   folder/subproject choices, explicit start date, complete counts/content,
   changed-source recovery and account/window masking. Keep new team work out
   of the private writer. Existing project order needs an exact reviewed append
   policy that preserves work added by others.
3. Finish native and genuine hosted acceptance; retain the isolated SQL regression suite:

   cancellation, complete creation, archived/revoked/changed source/destination,
   hierarchy/order/dates/labels/checklists, transport loss, relaunch/retry,
   duplicate requests, late account replies and failure rollback. Genuine hosted
   acceptance remains separate from local fixtures. Enable no rollout flag as
   part of these source and isolated-test stages.

The wider backlog and user-deferred release/provider/device work remain in
P2_PLAN.md. This foundation does not close shared workflow runs or rank 6.
