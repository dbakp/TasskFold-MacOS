# Shared completion selection recovery

Candidate only: no hosted deployment and no native rollout is enabled here.

## Request

`taskfold_review_team_completion_batch(_action, _body)` observes an exact saved
`taskfold_complete_team_tasks` request. `taskfold_cancel_team_completion_batch`
accepts the same arguments and may retire an unrecorded request. `_action` is
`complete` or `undo`; `_body` is the unchanged original group body, including all
member requests, frozen task records and any `related_request`/member history
links. A client must not rebuild the request from current tasks.

The envelope is at most 2 MB, each member at most 128 KB, with 1–100 unique task
identities. A response is at most 8 MB, including any complete replay receipt.
Accumulation is bounded inside the member loops as well as at return. Current
read access is required across every source and series project. A viewer may
review or cancel their own unrecorded intent; cancellation never grants editing.
The original action's actor, group/member nonces and full HMAC-bound body are
checked before receipt data can be used. A shape error is not a state certificate.

## Response

```json
{
  "group_review_protocol": 1,
  "account": "<current actor>",
  "team_id": "<team>",
  "request_id": "<exact group request>",
  "operation": "complete",
  "related_request": null,
  "state": "unrecorded",
  "items": ["<one full existing review_protocol:1 object per member>"],
  "receipt": null
}
```

Items are ordered by source task identity. Every item must match the corresponding
saved command and have the same state as the group. Each item uses the established
single-completion review contract, including current generation-scoped task,
series and successor observations, current role/capabilities and optional member
receipt. Responses cannot expose one accessible part of an inaccessible group.

| State | Meaning | Safe client interpretation |
| --- | --- | --- |
| `unrecorded` | No group or member nonce was recorded at observation time. | Inspect or retry the exact saved group. Absence alone never authorizes discarding it. |
| `recorded` | Every member belongs to the exact recorded group. | Validate the complete `batch_protocol:1` replay receipt; reconcile the complete connected queued cohort before acknowledgement. |
| `cancelled` | The group and every member have durable cancellation records. | The exact request cannot execute later. Only an explicit, fully fenced local recovery plan may retire the queued intent while preserving dependent work. |

For `recorded`, `receipt` is a full existing batch replay receipt with all member
`replayed` values true. It can be validated with `TeamTaskBatch.completionReceipts`.
Review and cancellation do not Undo a recorded completion. The receipt's current
rows may differ from the original source: later remote edits remain authoritative.
Missing/pruned/mismatched history is an error, never fabricated terminal proof.

For `cancelled`, `receipt` is null. The private group marker and member cancellation
records occupy the same nonce namespace as actual completion. Existing writers
refuse the whole retired group and isolated member attempts. A lost cancellation
reply is recoverable by either endpoint with the identical body. Cancelling an
unrecorded Undo or Redo does not consume the original group's history edge.

## Transaction and privacy rules

Both endpoints follow the existing completion writer's lock hierarchy: live team
and configuration, canonical projects, canonical group/member/history nonces,
then canonical task identities and current rows. No table receives client DML
grants. The new private cancellation marker has RLS and a cascading reference to
its private group ledger. Public wrappers are invoker functions; the private
helper has an empty search path and validates live identity/access. Completion
and cancellation contention yields one terminal outcome. A late failure leaves
no partial group/member tombstones or task changes.

Read/write pauses have distinct effects: disabled native editing does not prevent
reading or retiring an old intent when team reading remains allowed. Archived
projects remain reviewable with current read access and report no editing
capability. Missing access to any selected/series project refuses the whole review.

## Native work still required

1. Parse the versioned group response strictly against the entire frozen command.
   Refuse missing/reordered/foreign members, mixed states and incomplete receipts.
2. Add private transport bounds and account/origin/session-incarnation fences for
   both endpoints. A timeout must keep the original queue and its nonces intact.
3. Capture the full current queue/snapshot/workspace before recovery work. After
   each await, verify the snapshot/generation and live access still match.
4. Present all selected roots and dependent authored work using existing native
   review styles. Hide captured content after an access/workspace change.
5. Exact Retry keeps the original intent. Recorded Continue uses complete-cohort
   reconciliation and removes only the confirmed front header after persistence.
6. Offer cancellation only when the complete local recovery can preserve every
   dependent root/provisional edit and draft. Obtain a terminal cancellation
   certificate first, save a recovery copy, then publish the complete local plan
   atomically. A recorded winner follows the recorded path instead.
7. Exercise refresh/retry/cancel/recorded acknowledgement, storage failure,
   account/workspace/role changes, relaunch, later mixed edits and native Undo/Redo.
   Current Mac runtime, large-selection responsiveness and genuine hosted delivery
   remain unverified. Arbitrary shared bulk Reopen is separate from linked Undo.

Actual independently generated observations for native parser tests are retained
in `completion-batch-recovery/wire-fixtures.json`, with full query/advisor evidence
in `accepted.json`. The complete Px objective and user-deferred release/provider/
device work retain their existing scope.
