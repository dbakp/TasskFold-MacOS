# Private location draft transport

## Current scope

This is a transport foundation for privately sending an existing task's place-reminder proposal from Mac to a phone/tablet on the same account. There are no sending/receiving screens, automatic uploads, private-place synchronization, permission changes or new notification submissions in this milestone. Existing saved places remain on their devices. The transport API is not called by the normal Store. Rank 5 and Px remain incomplete.

Both apps own their protocol implementation, fixtures, SQL migration and development test runner independently. The backend migration is shared and applied once, not once per platform. Migration `20261022145128_private_location_handoffs.sql` matches the deployed history. No service credential is embedded in either app.

## Privacy and authority

A proposal has a place name, integer E6 coordinates, radius, arrive/leave choice and repeat choice, bound to an exact saved open task UUID, generation and completion revision. Account context comes from authentication, never user-editable metadata or an account field in the request. A recipient's accepted project membership does not grant access to another person's draft, even for the same shared task. Completion/reopening, replacement, task deletion and revoked membership cannot authorize an old proposal.

The table lives in the unexposed `taskfold_private` schema. Direct client table privileges are revoked, RLS provides owner checks, and public RPC wrappers are security invoker. One private security-definer driver performs explicit Auth-account, owner and current task-access checks with an empty search path. Its task-access predicate mirrors the current audited tasks SELECT policy; a future project-role policy change must review both predicates together. There is no Realtime publication or write to task/settings/comment/backup/widget data. Administrator/database access still exists: this is account-private storage, not end-to-end encryption.

A future Send control must explain that sending uploads the selected name and coordinates to Taskfold, require explicit confirmation, and never bulk-upload existing private places. Transport success must not be presented as permission, phone installation, reminder creation or delivery.

## Retry and review lifecycle

An account owns at most 32 live drafts and 256 retained records. A draft UUID is immutable within that account. Equivalent numeric JSON representations are normalized before digesting. Repeating the same put recovers its status without changing content, extending expiry or reviving a discarded/imported record. Changed content requires a new UUID. A fresh send must have been authored within the preceding 24 hours or at most five minutes ahead of server time.

A receiving device must save a private review ticket containing the account, task incarnation, draft UUID, immutable deadline, payload digest, device UUID and fresh nonce **before** making Claim. Only a pending record may create a fresh ticket. Same device/nonce retries recover a lost response; a different device or nonce cannot take over the claim. The UUID is an honest-client binding, not hardware attestation. Another device's list receives status without claimed coordinates or nonce. All responses omit the nonce and internal request digest.

The sender may discard only a pending proposal. A claimed proposal must be finished or abandoned by the same device/nonce; the sender cannot pretend to revoke a review already available offline. Finish records an import acknowledgement and clears geometry. It is not proof of task Save or OS delivery. Terminal status must never independently arm a reminder.

Drafts expire after at most 168 elapsed hours from authoring/server creation, whichever is earlier. Replies hide expired coordinates immediately. Finish, abandon and pending discard clear geometry immediately; task/account deletion cascades records. Owner requests and an hourly job clear expired payloads, so physical expired geometry removal can lag until maintenance runs. Metadata, including digests, remains for up to 720 elapsed hours plus the maintenance interval to refuse replays. Old authored requests cannot recreate a pruned proposal. At the 256 retained-record bound, finishing/discarding cannot free metadata capacity; clients must explain the retention wait rather than repeatedly retrying. Cron configuration and direct cleanup checks are verified; an actual scheduled hourly tick has not been observed.

## Client transport

The immutable models validate exact protocol fields, versions, UUIDs, scalar/coordinate/radius limits, time bounds, task incarnation, record count, claim privacy and mutation replies. An invalid item refuses the entire response. Native HTTP uses fixed POST RPC paths, authenticated account/session/workspace checks before and after awaits, disabled cookie handling, cache bypass/no-store, redirect refusal and a streamed 2 MB response cap. HTTP tests use an isolated in-memory URLProtocol; they do not prove real JWT/PostgREST integration.

The protocol cannot convert a proposal into an armed shared reminder or private archive by decoding it. It does not add location services to Mac. No name/geometry is put in the review-ticket header; that ticket is a model only and is not yet persisted by the apps.

## Required native integration before exposing Send

1. Persist/resume the private ticket across process loss, account changes, device-private identity reset and an interrupted Claim. Do not generate a replacement nonce for a claimed record.
2. Show an explicit phone review; save a reviewed private place and use the existing normal task Save/private-intent path. Recheck workspace, account, task incarnation and payload around every await. Permission and separate private consent stay explicit.
3. Atomically persist the task import receipt with the task change. Receipt authority must be monotonic across Undo, sync, snapshot replacement and backup restore so an imported draft cannot arm twice.
4. Retry Finish after the durable local commit; recover relaunches before/after both commits without guessing. Handle expiry, unavailable tasks, lost membership and full queues with accurate feedback.
5. Add native Mac authoring/status and the phone inbox, including explicit upload disclosure, cancellation, access errors, accessibility, large text, offline/retry and independent paired-device acceptance.

The transport foundation does not complete any of these native gates, real region delivery, background/cold/locked callbacks, remote reminders, general older-client rollout or distribution verification. Existing user deferrals remain unchanged.

## Verification

`p2-location-handoff-transport-evidence.json` records source hashes, deterministic Core checks, isolated app/extension builds, 28 local/hosted SQL assertions, rolled-back fixture counts and existing advisor findings. The local PGlite bootstrap deliberately lacks the complete production policies; the hosted fixture separately exercises the actual invitation lifecycle and current policies. No real task/account or saved private pin was used. See `Scripts/Database/README.md` for commands and transaction constraints.

The security advisor retains the same six pre-existing finding groups; none identifies this handoff schema. Performance advice includes the newly created, currently unused task foreign-key index on the empty private table. It is deliberately retained for deletion/cascade lookup; see the [unused-index advisor guidance](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index). Full existing finding names/counts and remediation links are in the evidence file. These results do not assert that the whole backend has no outstanding advisories.
