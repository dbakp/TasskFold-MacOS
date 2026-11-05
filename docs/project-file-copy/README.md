# Private project file preparation — 5 November 2026

This is the next partial step toward reviewed project file transfer. It creates and verifies private immutable copies of eligible original attachments. It does not share a file, change a project, publish custody, or authorize a transfer. The service and database gates default to Off; no hosted deployment or normal-use gate is changed.

## Behavior

A preparation binds the authenticated actor and live session, exact project inspection token, destination scope and a stable request ID. The current inventory must contain only eligible actor-owned stored references, with no unresolved legacy or unavailable references. It includes task, subtask and older inline-comment attachments from the preceding inventory milestone. Source names are retained privately; clients receive reviewed display labels, byte counts and progress rather than provider identities or paths. Original task/project context and files remain intact.

The service reads the original bytes through Storage, enforces the 5 MiB file limit, computes SHA-256 and rechecks the captured inspection before reserving a copy. Storage writes use the existing fenced upload ledger and a service-only generated immutable namespace, with upsert disabled. A successful readback must match the complete byte count and digest before the writer is reconciled and the private preparation becomes ready. An open writer ticket permits readback only, never another POST. Lost upload or ready acknowledgements therefore recover without duplicate upload. Source path traversal, malformed grants and corrupted copies are refused. All outbound requests use one fixed configured origin with redirects refused, bounded bodies and a bounded deadline.

Copies remain reserved, with no published attachment or team-content binding. Authenticated users, including the original owner, cannot read or overwrite that namespace directly. The service-only command validates a genuine live actor/session and temporarily enters only that actor's inspection context. Private tables/helpers have no direct client grants. Shared quota, operation locks and the existing rate budget apply. Preparations allow at most four live plans per actor, page progress by 100 items, expire after 24 hours and retain cleanup charges until provider cleanup is proved.

Check and Cancel remain available while preparation is paused. Copying refuses changed sources, closed plans, expired plans, lost access or paused upload/preparation gates. Cancelling changes the reserved ledger to cancelled; the existing fenced maintenance protocol owns eventual cleanup. Missing objects, timeouts and elapsed time never prove that an unresolved writer is finished. In particular, a lost reservation reply before a producer starts can leave an unresolved writer; terminal producer recovery remains separate work. There is no claim of complete retention/account-removal acceptance for preparation histories.

## Verification

`full-schema.json` records the owning migration history and 69 genuine local service checks. The production handler calls actual disposable Supabase Auth, PostgREST and pinned Storage APIs, with synthetic files and bounded tmpfs data. It verifies private preparation/replay, lost replies, exact copied bytes, direct-access refusal, stale-source refusal, cancellation, concurrent retries, gate pauses, plan quota/expiry, live-session validation, private privileges and unchanged original bytes, identity, metadata and task/project context. The owning complete-schema advisor retains only the previously recorded pg_net placement warning. Every owned fixture container/network is removed.

`verification.json` records 22 handler tests covering path and actor boundaries, write/readback contracts, corrupt bytes, lost replies, open tickets, aborts, malformed/overexposed progress, sanitized errors and the default-off gate. No extra dependency install is required. Both owning repositories run independently.

This is loopback internal-HTTP proof using the pinned file-backed Storage API. It is not hosted S3/TLS, a deployed Edge runtime, release/distribution proof or native acceptance. No Apple app code changed, so unchanged app builds and prior UI matrices were not repeated. Installed phone34 and Mac14 and their drafts remain unchanged. On-device-only assistance and deferred further iPhone installation remain the user's current decisions.

## Remaining transfer work

Explicit owner/audience consent and a signed file policy; atomic revalidation, mapping and custody binding with the project move; exact transfer receipts and encrypted native pending recovery; review/progress/cancel controls; legacy and other ownership/realm directions; discussion/download/access-retirement integration; wider concurrent replacement, removal, history and lifecycle acceptance; hosted provider verification. The existing unapproved-provider-custody commit refusal remains in place. A ready private copy cannot substitute for consent or a successful project-transfer receipt.

## Reproduce

Run from this repository, serializing the heavy owning-platform fixture:

```sh
python3 Scripts/check_test_storage.py --path /tmp
deno test supabase/functions/project-files/handler_test.ts
deno run --allow-run --allow-env --allow-read --allow-write --allow-net=127.0.0.1 Scripts/Database/test-full-schema-project-file-copy.ts /tmp/taskfold-project-copy-own.json
```

The service entry point retains platform JWT verification and requires both its explicit environment gate and the private database gate. No configuration secrets belong in app sources or documentation. Production SQL only reads Storage metadata; file bytes are written/read through its API. This repo owns all source, migrations, tests and future deployment inputs.
