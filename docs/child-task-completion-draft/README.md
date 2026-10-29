# Independent child completion: saved intent foundation

This stage adds `ChildTaskCompletionDraft` to each app’s own Core and app target. It is a strictly decoded, immutable review value, not a server receipt, mutation, optimistic task patch or shipping completion route. No ordinary feature flags or hosted schema changed.

## Implemented

- Capture an explicit Complete or Reopen action with a fresh request identity, root generation, project, independently addressed child identity/incarnation/revision, and account/origin/workspace/session/access binding.
- Persist only the completion cohort’s original presence and values: completion state/time, heading marker and completion epoch/version. Titles, descriptions, the parent tree and unrelated fields are absent from the intent; diagnostic descriptions are private.
- Revalidate a newly read record before use. Versioned children may retain disjoint field edits. A changed completion token, completion-time change, replaced child, changed project/root generation, stale revision or changed live scope requires review. A completed–reopened cycle is refused even when the final visible state is open again.
- For legacy children without completion metadata, require the exact captured node revision. This is a temporary refusal rule, not the legacy adoption implementation. Null/malformed/exhausted tokens, headings, future task types, malformed completion states and no-op actions are refused.
- Decode saved values through the same validation, reject extra envelope/body keys, and bound the completion body to 4 KiB. Generic child-field commands remain unable to carry completion changes.

A later stage now supplies the [disabled dedicated server candidate](../child-task-completion-server/README.md). This document records the client draft foundation’s own verification scope; the full app-facing feature remains unfinished.

## Remaining in the completion/Undo stage

- Server deployment and complete client integration remain open. The later disabled server candidate implements admission, exact request idempotency, completion history/projection and permission/role/concurrency checks in isolated fixtures; the client draft is still not connected to its RPC.
- Receipt-certified Undo must restore the original completion time while advancing the completion revision, preserve all unrelated fields, and refuse intervening completion cycles. A client draft alone must never authorize Undo.
- Durable attempted/confirmed retry handling, transport, Store and premium native review/feedback integration.
- Independent database/advisor coverage, app builds and genuine lifecycle/native accessibility acceptance for the completed path.
- Existing structure, legacy/adoption and authoritative child migration work, and all previously agreed deferrals.

The existing team checklist adapter stamps `completed_at` from the command’s event time when state changes (`20261026155711_team_task_heading_commands.sql`). Consequently a generic checklist patch is insufficient for historical-time restoration by Undo. The dedicated server implementation must address this rather than routing Undo through ordinary field edits.

## Verification

`verification.json` records exact source hashes, selected Core results and project membership checks. These are host Core tests of each repository’s independent source, not iPhone/iPad runtime acceptance. Existing package-wide Swift concurrency warnings remain; this stage makes no warning-free full-app claim.
