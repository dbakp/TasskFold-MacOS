# Full repository replay and genuine local subtask APIs

Reviewed 3 November 2026. Each app repository now owns the historical database inputs it previously read indirectly from the web reference: 28 files copied into this repo. Original timestamps and SQL are retained except the documented replay repair. There is no sibling-repo runtime/build dependency. The owning full test replays 202 migrations, with exact hashes recorded in `full-schema.json`. The repos retain their independently created migration filenames.

## Concrete fixes

1. Collaboration's owner-insert transition now removes the older same-named policy before creating its intended strict authenticated-owner policy. Previously a fresh complete replay failed on the duplicate policy. No hosted migration was executed.
2. The undeployed recording-restoration candidate now patches `audio_maintenance_recovery_v4` when the scheduler has retained that implementation behind its wrapper. It falls back to the unwrapped implementation for existing isolated providers. Strict body-anchor checks remain. The complete replay checks that the scheduler wrapper is preserved, expiry pruning reaches the actual worker and the retained worker remains unavailable for direct service-role execution.

## Verified scope

Pinned actual Supabase PostgreSQL, GoTrue Auth, PostgREST and Storage services run with disposable tmpfs data. A transparent local gateway routes HTTP and the official read-only advisors connection; it does not fabricate sessions, table reads or RPC responses. The database/Auth/REST/Storage network is internal, the gateway publishes only on loopback, and cron job launching is disabled before any historical schedule is installed. No outgoing job was queued. Generated service credentials stay in disposable process/container configuration and are excluded from reports. All owned containers and their network are removed after the run.

Each repo independently passes 72 checks: genuine signup/profile creation; all 15 required workspace tables; scheduler wrapper/ACL checks; normal project/task creation; disabled child reads by default; unreviewed-root refusal; explicit exact-tree trusted adoption and promotion of one synthetic root; real authenticated child reads; a prepared child field edit after a different sibling changes; exact idempotent retry with the original request unchanged; opaque JSON and root preservation; real second-user RLS isolation; refusal of invalid tokens and signed-out sessions; fresh password sign-in and saved child data; restoration of the local child flags. The queue is an in-memory API request, not an app Store queue. The retry checks the real server receipt but does not inject an actual transport interruption.

Each repo also passes 65 existing recording-generation/provider regressions after the candidate repair. That focused suite uses its documented synthetic Auth adapter, actual local PostgreSQL/Storage and no added advisor findings; it is separate from the genuine Auth run. Swift app sources were unchanged, so no new app-build/native-UI acceptance is claimed.

## Remaining work

The complete-schema official advisor has 15 warnings: 14 legacy per-row Auth evaluations in RLS policies and nonrelocatable pg_net extension placement in public. They are recorded, not treated as a clean advisor result. Resolve the legacy policy performance warnings and review the extension installation path before rollout. No metadata or service-role claim from user-editable profile data authorizes the tested APIs.

Actual native Backend/Store sign-in, durable offline queue/merge/cache persistence, cold recovery and other account/window/platform contexts remain unaccepted against this stack. Trusted fixture promotion does not establish the app's full new-account/legacy adoption workflow. Shared audio/file Edge handlers, genuine S3/hosted integration, larger mixed histories and the broader migration remain open. All normal-use app gates and existing user deferrals are unchanged. Nothing was deployed or enabled in the hosted project.

## Reproduce

With the pinned images in `Scripts/Database/full-schema-runtime.mjs` available, run the owning repo's `node Scripts/Database/test-full-schema-sync.mjs /tmp/taskfold-full-schema-<unique>.json`. It checks the 20 GiB storage floor before starting. Use Node 22+ and the installed Supabase CLI for advisors. `Scripts/Database/test-audio-generation-restore.mjs` is the separate focused regression. Prior failed setup/replay attempts and corrections are qualified in `attempts.json`. Two obsolete ignored `.build` caches were removed; current app products and the active Core caches remain.

References: [official local development](https://supabase.com/docs/guides/local-development/cli/getting-started), [official service configuration](https://github.com/supabase/supabase/blob/master/docker/docker-compose.yml), [Auth configuration](https://supabase.com/docs/guides/self-hosting/auth/config). This is complete repository replay on a pinned local platform, not proof of hosted-schema drift parity or release readiness.
