# Team content custody — disabled foundation

24 October 2026. This migration is local and undeployed. Team project admission,
role-based access and native team controls remain unavailable. It builds on
TEAM_ORGANIZATION.md; it does not complete advanced teams or rank 6.

## Why ownership needs to change

A schema-only inspection of the current hosted database confirmed that projects,
tasks, sections, activity ownership and generation ownership reference Auth users
with cascading deletion. A shared team needs to retain its work after an author
removes their account, independently of its current owner. Reassigning every task
to each new owner would change creator fields and offline baselines.

The candidate instead keeps existing non-null UUID creator fields and all native
row/wire shapes. Those five foreign keys reference a private UUID-only content
identity registry. The registry holds only `id` and `removed_at`, no email,
profile, credential or token. Auth registration installs its trigger before the
backfill, holding the Auth table lock through the migration transaction so a
concurrent signup cannot be missed. Removed identifiers cannot be reused. Each
repository owns its migration and acceptance harness independently.

Explicit account cleanup preserves the previous personal-project behavior:
owned personal projects, personal tasks, personal sections/history/generations
are removed; a different creator's surviving tasks detach from deleted personal
projects/series. Team project/task/section records, activity and generation
identities survive. Auth profiles, memberships, devices, comment actors and
assignees retain their existing Auth deletion/nulling rules. New personal creator
references still lock a live Auth row, so moving the FK does not allow a stale
JWT to recreate personal data. Existing default-owner project capture is retained.

## Private custody and closed access

Private project bindings identify team-owned content. Task/generation custody
records survive task deletion, preserving generation tombstones and shared audit
history when the original author later leaves. Original creator UUIDs stay stable
across ownership transfers; no task copy or creator rewrite is needed. Activity
continues to record real transitions after its original creator's Auth record is
gone. A new binding locks the creator before admission to serialize with account
removal. Current admission has **no client grant or callable API**; tests seed it
through privileged SQL only. Reviewed hierarchy, sharing/import and folder
placement decisions are required before adding an admission endpoint.

Restrictive policies close all team project/task/section/activity/collaborator and
bound-file paths for authenticated clients. They override legacy creator-only OR
policies. The existing public project-access and owner helper signatures remain,
with invoker wrappers over a private fixed-path lookup preserving personal sharing
while returning false for team projects. The service automation project lock also
rejects team destinations before its legacy owner shortcut. Native guarded edits
and deletes remain opaque for inaccessible team rows; an inaccessible delete may
acknowledge idempotently but does not delete the server row.

Database cascades bypass RLS. A subject-bearing native/service mutation therefore
also passes a trigger guard on team tasks/projects/sections. Deleting a personal
series root cannot cascade into a closed team task. Explicit team deletion uses
private transaction authority that clients cannot set; it is removed on success
and rolled back on failure. SQL operators and account-maintenance operations
without a subject retain their trusted database role. No public scope-setting
function or caller-controlled setting grants the exception.

These are interim closed gates, not the finished team permission model. The team
configuration must stay disabled. Roles must next replace the closed gates at
native/direct-data/API/email/comment/storage boundaries, with revocation and
concurrent changes verified. No current personal project is enrolled or rewritten
by the migration, and no hosted schema or app process was changed in this work.

## Files and deletion

Only objects in the inspected private `task-attachments` bucket can be bound.
Public avatars cannot become team attachments. Initial binding checks/locks the
uploader against account-removal authorization. Bound objects are excluded from
that person's removal file list, and the existing restrictive storage policies
hide them even from a still-valid old uploader token. Buckets containing bound or
pending-cleanup objects cannot become public, and objects cannot be moved to
another bucket through an unreviewed metadata update.

Releasing a binding creates a private cleanup record. File access stays closed
while cleanup is pending. Team deletion remains blocked until the actual Storage
workflow has removed the object: removing the binding alone is insufficient.
On a later successful team deletion, entries whose object metadata is gone are
pruned, tasks/projects/sections/activity are deleted atomically, and UUID-only
generation/custody tombstones remain. The database never deletes Storage object
metadata itself. A future reviewed Storage API workflow must perform deletion,
await its result and support retries. Current tests simulate that provider boundary
with disposable object metadata; they do **not** prove real object-byte transfer,
deletion, signed-URL expiry or provider delivery.

## Verification

Run from the repository root:

```
node Scripts/Database/test-team-content-custody.mjs docs/p2-team-content-custody-evidence.json
```

Or run `npm run test:team-custody` inside `Scripts/Database`. Both repositories
independently pass 93 checks on the pinned owned PostgreSQL 17.6 fixture, using
actual migrations, SQL roles, RLS, native edit/delete routines, service API task
entry points and authenticated team transfer/delete calls. The additional fixture
dependencies model inspected hosted schema prerequisites; they are not a full
hosted database or HTTP/native UI acceptance run.

Evidence covers:

- Exact retained task, section and generation rows after author removal; deleted
  team task history/generations and continued activity for a departed creator.
- Explicit ownership offer/acceptance and subsequent former-owner removal without
  changing the task, alongside unchanged personal/shared-project deletion rules.
- Closed native reads, direct writes, cross-boundary moves, guarded edit/delete,
  project helper lookups and service API team create/get/list paths.
- Actual service API personal creation and shared-project results, preserving a
  different creator's task visible through ordinary project ownership.
- Public-bucket binding refusal, private-bucket preservation, pending cleanup,
  blocked team deletion and the eventual authorized team delete.
- Real concurrent transactions in both personal-creation/removal orders and a
  project-admission/removal overlap, with no lost team work or personal orphan.
- A native personal-root deletion cannot cascade into a linked team task; the
  denied operation preserves both rows and leaves no transaction authority behind.
- Stale deleted-account creation refusal, deleted profile cleanup, registration,
  original project default-owner capture and private table/grant boundaries.

Official read-only advisors report no errors and no new custody/helper warnings.
Seven known minimal-fixture Auth-init-plan warnings remain in its original
permissive policies; they are recorded, not presented as hosted findings. Every
owned container/loopback port is removed in `finally`. Each evidence file records
its actual migration SHA-256. The pre-existing 144-check team lifecycle suite is
separate evidence and does not by itself verify this custody migration.

Before enablement: implement reviewed admission and current role permissions;
reject cross-workspace structural links and unauthorized moves; add safe native
team/folder/admin flows; verify account-removal explanations, backup/restore,
activity attribution and widget privacy; verify actual Storage/email/API/hosted
and native acceptance. Existing user deferrals and the full ranked Px scope remain.

The subsequent project-role/native-read stage is described in
[TEAM_PROJECT_ACCESS.md](TEAM_PROJECT_ACCESS.md). It replaces the closed native
read policies with verified session/membership rules behind a default-off flag;
editing, service access and native workspace integration remain closed/pending.
