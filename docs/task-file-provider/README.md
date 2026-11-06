# Real local Storage integration and wrapped absence recovery

Reviewed 2 November 2026. Each repository owns its service, provider fixture and dependency paths independently. Nothing was deployed, scheduled or enabled for ordinary use. No real user tasks, hosted credentials, existing Docker containers or persistent Docker volumes were used.

## Product fix

The real pinned Storage API v1.87.2 returns HTTP 400 for an absent object with `{"statusCode":"404","error":"not_found","message":"Object not found","code":"NoSuchKey"}`. The worker previously required HTTP 404. It deleted the abandoned file successfully but retained its quota allocation as unresolved. The worker now accepts HTTP 400 only when both the exact `NoSuchKey` code and string `statusCode: "404"` are present. Existing HTTP 404 handling remains. Generic 400s, bucket errors, forbidden responses and provider failures still cannot establish absence.

A claimed closed allocation still requires no open writer, complete verified bytes before deletion, deletion through the Storage API, absence readback and the exact fresh SQL claim with absent provider metadata before quota release. Provider absence never settles an unresolved write. This fix does not authorize caller-selected paths or trust elapsed time as evidence that a write stopped.

## Verification

The provider suite executes the actual Taskfold HTTP handlers and unchanged candidate SQL against a real pinned Storage container and its real metadata/schema. It covers upload/download, exact identity and hash, private namespace RLS with a successful ordinary authenticated-prefix control, current viewer access and withdrawal, expired sessions, retry after lost upload/finalization replies without duplicate POSTs, cancelled-file deletion, lost-delete recovery with a renewed claim, published-file preservation and a complete 5 MiB binary round trip. Each owning report records actual pass counts and advisor comparison. Service tests separately cover the newly observed response plus rejection cases and retained SQL authority.

Auth and RPC HTTP routing are minimal local adapters, with synthetic signed tokens and actual SQL sessions/access decisions. The Storage API validates those tokens and applies its real role/policy path. The file backend is ephemeral memory. This is real local provider integration, not full Supabase-stack migration-history parity, genuine hosted Auth, S3/cloud deployment, native authenticated publication, multiple real users/devices or distribution acceptance. Normal publishing and maintenance switches remain Off. Previous native/Core evidence is unchanged and was not counted as rerun.

## Reproduce and storage

Use Node.js 22 or newer (the recorded runs use 24.19.0), Deno and Docker. First run `python3 Scripts/check_test_storage.py --path /tmp` and require its 20 GiB floor. Pull the exact `storageImage` digest in `Scripts/Database/storage-provider-fixture.mjs`, then run `node Scripts/Database/test-task-file-provider.mjs /tmp/taskfold-provider-report.json`. Run resource-heavy repositories sequentially. Run the three task-file Deno test files and lint the two service directories plus the four new provider fixture modules.

The fixture replaces only the explicitly minimal bootstrap objects/buckets stubs with Storage's own schema. Production migrations execute unchanged. It owns randomly labelled containers and a network, uses loopback-only HTTP ports, mounts no host files and creates no persistent volumes. Responses have a referenced deadline and a bounded body read. A failed test still attempts to close every owned resource; labels are checked before removal. Existing shared fixtures gain only a read-only owned-container identity for this attachment. No Docker reset or broad cache cleanup is part of the workflow.

Provider API behavior was checked against the current official [Storage deletion guidance](https://supabase.com/docs/guides/storage/management/delete-objects), [error-code documentation](https://supabase.com/docs/guides/storage/debugging/error-codes) and [pinned upstream release](https://github.com/supabase/storage/releases/tag/v1.87.2). The current changelog was reviewed; the upcoming hosted TLS-cipher change does not change this loopback fixture or its service protocol. Hosted TLS and rollout verification remain separate.
