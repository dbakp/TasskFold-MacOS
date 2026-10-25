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

## Required next implementation

1. Add a gated atomic service command. Authenticate and lock current memberships,
   source definition and destination/tree/order state. Recheck readable source
   and editing/creation authority, active/archive state and exact reviewed source
   and destination revisions. Validate all new identities, hierarchy, sections,
   task fields, shared labels and checklist metadata; accept the whole run or
   roll it back. Do not grant broad direct writes or infer authority from creator IDs.
2. Use one durable account/origin-bound request and receipt for the entire run.
   Freeze rows, dates, identifiers and destination ordering before sending;
   lost replies/relaunch retry the same request. Match receipt identities and
   source/destination context exactly. Recheck current access for receipt replay.
   Conflicts require a fresh explicit review; no partial retry or silent rebase.
3. Build native destination/content reviews in each app. Support audience and
   folder/subproject choices, explicit start date, complete counts/content,
   changed-source recovery and account/window masking. Keep new team work out
   of the private writer. Existing project order needs an exact reviewed append
   policy that preserves work added by others.
4. Verify with isolated SQL transactions and signed phone/tablet/Mac flows:
   cancellation, complete creation, archived/revoked/changed source/destination,
   hierarchy/order/dates/labels/checklists, transport loss, relaunch/retry,
   duplicate requests, late account replies and failure rollback. Genuine hosted
   acceptance remains separate from local fixtures. Enable no rollout flag as
   part of these source and isolated-test stages.

The wider backlog and user-deferred release/provider/device work remain in
P2_PLAN.md. This foundation does not close shared workflow runs or rank 6.
