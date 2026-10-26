# Shared heading creation, deletion and restoration

26 October 2026. Both owned repos now implement typed lifecycle commands through
the existing team lifecycle and atomic selection RPCs. This follows TEAM_TASK_TYPES.md.
No hosted configuration, rollout or normal heading gate changed. The later native
picker follow-up and its exact acceptance are in TEAM_TASK_TYPE_NATIVE.md.

## Transport and authoring

The signed workspace boundary now advertises `task_type_lifecycle_protocol: 1`
when the existing team/read/edit gates are enabled. It is independent of
`task_types_protocol`, whose authoring flag still defaults off. Both fields are
included before hashing the boundary token. Captured scopes retain both optional
versions in durable commands; missing fields in legacy scopes remain compatible.

Root or recognized nested type metadata requires explicit lifecycle version 1 in
the body and receipt. This includes a server's ordinary null type column, fixing
the earlier lifecycle whitelist refusal. Plain legacy rows with no type metadata
retain their previous body and receipt. Unknown versions and task types refuse;
they do not fall back to an ordinary task or personal writer.

Creating a new root or nested heading also requires the captured authoring
capability and the live private authoring flag. Every heading must be open with
no completion timestamp. Known headings may be deleted or restored through their
certified Undo while new authoring is paused. The global edit/read/team/session,
role and archive gates still apply, including recorded retries. The separate
transport capability lets clients preserve known work without granting new type
authoring. Native Store integration now retains client opt-in and negotiated admission;
see TEAM_TASK_TYPE_NATIVE.md for the scoped native follow-up.

## Preservation and recovery

The lifecycle retains existing live authorization, lock order, generation and
request identities, scope, full deletion review, recipient checks, conversation
archive, recurrence links and restoration hashes. Restoration hashes cover the
complete typed task. A forged root or nested type fails rather than changing the
deleted content. Restore uses a fresh root generation and resets its server
completion counter; certified nested data retains its saved state and identity.
Existing assignment eligibility rules remain authoritative during restore.

Notes, planning fields, recurrence settings, root/nested type flags and productive
descendants survive the verified delete/Undo flows. Normalized discussion content,
authorship and original creation time also survive; restored comments deliberately
get fresh IDs and revisions so old callbacks cannot target restored conversations.
The same command identity is retained for retry. Old create/delete retries cannot
resurrect or remove a new incarnation; restore replay returns newer current content
without applying historical fields again.

Atomic selection envelopes accept the member lifecycle protocol and require an
explicit typed receipt. Each member still has a captured source and unique action
identity. A missing member protocol rejects the whole selection without partial
removal. Group Undo uses the existing certified complete-selection authority.
No public grant, direct writer, personal merge or provider behavior changed.

## Verification

Each repository passes 179 selected Core cases, including 8 new lifecycle cases
and existing task type, lifecycle, checklist, batch and workspace regressions.
Cases include capability separation, null/legacy rows, malformed/completed types,
durable serialization, typed acknowledgement, selection Undo and actual SQL
create/delete/restore receipts saved as a synthetic test fixture.

Each owned service source passes 100 checks in a real isolated PostgreSQL fixture:
default-off creation, roles/session refusal, root/nested creation, hierarchy and
recurrence preservation, delete/restore during authoring pause, forged Undo
refusal, exact task fields aside from normal incarnation/counter resets, normalized
conversation recovery, safe retries, ordinary null-column and legacy behavior,
atomic mixed selection refusal/removal/Undo, capability advertisement and helper
privileges. Advisors show no new warnings; both test containers were removed.
Both current-source arm64 Debug apps build without signing. Runtime acceptance
is not established by a build or fixture.

Next: native Store/editor creation/conversion controls using negotiated capabilities,
Save/Undo/recovery and account/source-change acceptance, shared template/import
adapters, and broader Mac, spoken/largest-text and cross-device checks. Hosted
rollout, old-client upgrade handling, distribution and user-deferred providers and
notification delivery remain deferred. This stage does not close rank 3 or Px.
See team-type-lifecycle/ for source bindings, results and harness corrections.
