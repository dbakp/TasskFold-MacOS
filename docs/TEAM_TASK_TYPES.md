# Shared task-type edit commands

26 October 2026. First source stage of the shared heading adapters. Both repos
own a compatible client command and SQL migration; no hosted changes or rollout
switches were enabled. Native type pickers and the Store authoring gate are still
unchanged. This is command/service verification, not a shipped shared editor.

## Protocol

`native_task_types_enabled` is a new private configuration column, default false.
The workspace boundary advertises `task_types_protocol: 1` only when the existing
team/read/edit gates and this flag are enabled; otherwise it advertises zero.
The field is included before hashing the boundary token, so availability changes
invalidate captured editor admission. Existing role, session, archive and origin
checks remain authoritative; knowing the version grants no access.

A captured TeamTaskEditScope retains the optional version in durable Codable
commands. Root type changes and new/changed recognized nested types require the
version and send an explicit protocol marker through the existing edit RPC.
Ordinary edits retain their previous body. Unknown versions and unsupported state
refuse rather than falling back to the personal writer. Heading creation remains
refused by the existing lifecycle adapter until its own protocol is implemented.

Root type edits require an explicit boolean and a complete captured type,
completion state, timestamp and revision. Reopen is separate: conversion cannot
be combined with completing/reopening. Capture rechecks current root context.
Nested conversion requires open source and desired nodes; it advances the existing
checkbox revision while preserving its epoch. Captured nested conversion also
refuses changed revisions, states/types, removed nodes or newly colliding IDs.
Opaque data is retained; only recognized subtasks are interpreted as containment.

The service retains live actor/session/role/team/project/archive checks, task
identity/generation, existing locks, request fingerprint, scope and transactional
merge. It validates type context before a new write. Nested type edits participate
in the existing revision checks and tree merge, so old checkbox actions cannot
cross conversion or its Undo cycle. Known heading state invariants still apply.
Recorded retries return current rows without reapplying historical values, even
if type availability has subsequently paused. Fresh requests remain paused.

Typed receipts must confirm version 1 and a readable valid task type/tree before
the client acknowledges them. Durable commands keep the request identity and
baseline across serialization; Undo retains the typed scope and uses explicit
false for a legacy ordinary root. A missing/invalid receipt keeps the action for
review. No new public RPC grants, direct-writer permissions or personal merge
changes are introduced. Private helpers have no client execution grants.

## Verification and remaining work

Each repo passes 158 selected Core checks, including 8 type-command cases and the
existing task edit/checklist/recurrence/workspace/type regressions. Each owned
migration passes 72 real isolated PostgreSQL checks, including root and nested
conversion, field/descendant preservation, explicit Undo, stable retry identity,
current-state replay, capability pause, boundary-token changes, stale checkbox
and completion-cycle refusal, minimal ordinary edit compatibility, unauthorized
roles/sessions, direct-write refusal and private helper grants. Database advisors
have no new warnings; both owned containers were removed. Each independent arm64
Debug app build passes without signing. No native runtime acceptance is claimed.

Next: connect the existing native Store/editor controls to the negotiated type
capability; add native Save/Undo/recovery/source-change checks; complete typed
creation, deletion/restore, shared templates/import and their capability/receipt
adapters. Existing lifecycle payload whitelists do not yet accept the new root
type column, including its null representation, and refuse those payloads. They
must be updated before exposure; conversion support is not lifecycle acceptance.
Wider hosted, cross-device, spoken/largest-text and installed-widget acceptance
remain open. Normal authoring, collaboration rollout and user-deferred older-client,
provider, notification and distribution work remain unchanged. Rank 3 and Px stay
active. Evidence is in team-task-types/.
