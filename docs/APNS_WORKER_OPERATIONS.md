# Native reminder worker operations

The native worker is deployed with delivery disabled. Each native repository independently owns the identical backend contract and worker release files. Deploy the reviewed version from one repo and synchronize the exact source/version into the other; do not deploy competing versions from separate native releases. Never place APNs keys, service keys, installation capabilities or device addresses in app/widget bundles, task records, backups, logs or repository files.

## Current state

`dispatch-reminders` v6 uses custom service authentication (`verify_jwt=false`, checked by the handler). Retrieved source matches both owned copies. Its distinct 256-bit secret is configured in Edge secrets and Vault; delivery is explicitly false. The new `taskfold-native-reminder-sweep` 30-second cron is installed **inactive**, with owner-only Vault-backed invocation. The existing `check-due-tasks` v13/web minute cron remains active and unchanged. No APNs credentials/provider delivery have been added. Actual HTTP smoke verifies anonymous POST 401, authenticated GET 405, authenticated POST 200 `{ "status": "disabled" }` and caller-cursor POST 400. Final cursor is idle and fixture Auth/device/job rows are absent.

## Required private configuration

| Secret | Meaning |
| --- | --- |
| `TASKFOLD_REMINDER_CRON_SECRET` | A distinct random service secret of 32–512 characters. Invoke using `x-cron-secret`; never reuse a public/client key. |
| `TASKFOLD_APNS_DELIVERY_ENABLED` | Only exact `true` arms dispatch. Keep `false` until every rollout gate below is accepted. |
| `TASKFOLD_APNS_KEYS` | JSON array of one to four explicitly scoped signing entries: `platform`, `environment`, `bundle`, `teamID`, `keyID`, `privateKey`. `privateKey` is the PKCS#8 .p8 PEM, stored solely in backend secrets. |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Platform-provided backend connection; service key never reaches native clients. |

Allowed pairs are iOS / `com.dbakp.taskfold` and macOS / `com.dbakp.taskfold.mac`, each with `development` or `production`. Keys must authorize the exact topic and environment in Apple Developer. Duplicate scopes, invalid IDs/PEM and missing HTTP/2 capability fail closed before any queue claim. The worker does not infer production from Debug/Release, borrow another environment's credential or fall back to HTTP/1.1. Native registration must read its signed entitlement and fresh token instead of guessing that environment. Use the Supabase secret UI or CLI `secrets set --env-file` with a private temporary file; keep values out of shell arguments/output and delete that file afterward.

## Bounded invocation and scheduling

Authenticated **POST** accepts no query parameters. The database owns the cursor; the previous optional `after` parameter is now rejected even with valid service authentication. No body is required. An inactive rollout returns `disabled` before touching the database/provider. When enabled, the handler acquires one two-minute sweep lease, maintains expired bindings/receipts, reads a page of up to 20 device IDs and reconciles/claims at most four jobs per device. Provider/database calls retain eight-/five-second timeouts and a 50-second invocation budget. Scheduled preparation additionally verifies the current sweep nonce; a late response rechecks the time budget before dispatch. Counts/bounded diagnostics contain no task titles, tokens, notes, addresses or exception/body text.

A successful response reports `processed` or `paused`, aggregate counts and informational `nextCursor`. The server commits its fenced cursor before responding; callers must never persist or attach their own cursor. `busy` means a live sweep or global provider backoff, with no device/job/provider call. A paused run retains the preceding fully processed device. Only an exhausted successful page cycles to the start; pausing at NULL cannot invent a completed sweep. Error/lost-response recovery retains the saved position; old nonce/baseline/expired receipts cannot rewind a later commit. Errors retry after 30 seconds; provider pauses use 30–3600 seconds. Individual job/provider receipt ambiguity still requires OS deduplication acceptance.

The owner-only `taskfold_private.invoke_reminder_worker()` resolves the unique Vault names `taskfold_reminder_project_url` and `taskfold_reminder_cron_secret`, validates configuration and enqueues one POST with a 60-second HTTP timeout. The Edge secret must match the Vault service secret. Setup is accepted and private temporary files were deleted. Cron SQL contains only the helper call. Keep the job inactive and `TASKFOLD_APNS_DELIVERY_ENABLED=false` until all gates pass. Rollback disables both; already accepted provider alerts cannot be recalled.

Service-only `taskfold_reminder_sweep_status()` reports running/retry/sweep start/end/completed count and bounded last-run aggregates, omitting cursor/nonce. Monitor a sweep older than 15 minutes and stop rollout at 30 minutes, before the one-hour catch-up horizon. Also monitor oldest due backlog, exhausted jobs and repeated paused/502/503/missing invocations. A 20-device page/30-second schedule is a cap, not a proven latency bound; actual jobs/provider calls can consume the budget earlier. Load/sweep-latency acceptance and an operational owner remain release gates.

| Response/receipt | Operational meaning |
| --- | --- |
| 401 / 405 / 400 | Fix service authorization, method or cursor. No work is dispatched. |
| 200 `disabled` | Switch off. No database/provider request. |
| 200 `busy` | Sweep lease or global retry delay active. No device/job/provider request. |
| 503 | Missing/invalid provider/backend configuration. No claim. |
| 200 `paused`, retry count | Provider/transport/configuration failure or remaining time budget. Revisit previous cursor after the appropriate delay. |
| `receiptRejected` | Task/access/account/device/lease changed while sending. Never treat the attempted provider request as a current confirmed send. |
| 502 | Database/validation failure; private details withheld. An accepted provider request may have lost its acknowledgement. Do not immediately resend that occurrence manually. |

The queue contains bounded outcomes only. Use service-only aggregate state/outcome/age/attempt metrics, not raw bindings or task content, for diagnostics. Alert on growing due backlog, failed/exhausted outcomes, repeated paused/503/502 responses and registration failures. Signing/topic errors halt a batch and use a 15-minute delay; fix credentials instead of retiring devices. Known `BadDeviceToken`, `DeviceTokenNotForTopic`, `Unregistered` and `ExpiredToken` responses retire the current fenced binding; the app must obtain a fresh registration. Unknown 4xx responses halt without retiring or permanently losing every affected event. APNs 5xx waits at least 15 minutes. Retry-After is bounded to one hour and cannot shorten the database's exponential backoff. Eight attempts and one-hour catch-up expiry remain the maximums.

## Activation and rollback gates

1. Accept the independently implemented inactive native lifecycle on final provisioned binaries: fresh-token callbacks, signed environment/topic, permission/time-zone/token changes, account-incarnation fencing, secure revision persistence and proof-based retirement on sign-out. Implement explicit device opt-in after delivery authority is accepted. Core fixtures/iPhone local UI pass; actual signed-token, physical and Mac runtime acceptance remains. Keep native remote activation unavailable until these gates pass. See [lifecycle contract](REMOTE_REMINDER_DELIVERY.md#inactive-native-registration-lifecycle--6-october).
2. Implement one delivery authority per event/device and reconcile pending local requests. Preserve local snoozes/Focus as intended; verify offline/lease expiry/reconnect behavior. Stable APNs IDs/collapse do not prove deduplication. Test ambiguous provider acceptance, delayed stale notifications and current-state action validation.
3. Configure sandbox credentials privately, verify hosted HTTP/2 execution, real APNs acceptance and a physical iPhone's foreground/background/terminated delivery. Test reschedule/complete/delete/restore/travel/permission/account switches, invalid token and downtime. Separately verify signed Mac closed-app delivery when desktop testing is available.
4. Accept the implemented durable cursor/nonce and inactive cron at real cohort/device/job volume; verify full-sweep latency and outage recovery. Monitor only private service aggregates and establish an operational owner. Adopt an explicit recipient policy before collaborator-wide reminders; the current queue delivers owner occurrences only.
5. Enable a small accepted cohort, compare actual OS display/actions with queue receipts, then expand. Do not remove the legacy web worker or enable both local and remote delivery independently for one device occurrence. Production signing/release and physical acceptance are separate gates.

Rollback by setting `TASKFOLD_APNS_DELIVERY_ENABLED=false` and stopping the native cursor scheduler, then have the apps explicitly retire/disable remote bindings and restore the verified local authority path. Already accepted APNs notifications cannot be recalled. Do not replay failed/obsolete jobs, reset generations or remove receipt/installation fences to recover delivery.

## Reproducible checks

Run `Scripts/test_reminder_worker.sh` in either repo. It uses no credentials or network permissions: 30 native provider/worker fixtures plus five web compatibility fixtures and both entrypoint typechecks. The signing test creates an ephemeral P-256 key and verifies the resulting JWT, without any production key. Run `supabase/tests/reminder_jobs.sql` against an isolated accepted backend using actual client/service roles; it wraps all Auth/device/task fixtures in a transaction and rolls them back. All deployed provider/cursor migration files must match backend history before rollout. Run `supabase/tests/reminder_worker_cursor.sql` for actual-role/45-device/deleted-cursor/current-payload checks. Run `reminder_sweep_hold.sql` and `reminder_sweep_compete.sql` on separately established connections; the marker requires real overlap, and both transactions roll back. Never run concurrency fixtures with the native cron active. Passing these checks does not prove APNs or OS delivery.

Reference contracts: [Apple request/HTTP2 headers](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns), [Apple token signing/refresh](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns), [Apple responses/retry guidance](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns), [Deno HTTP clients](https://docs.deno.com/api/deno/fetch/), [Supabase service-function authentication](https://supabase.com/docs/guides/functions/auth), [Vault-backed scheduling](https://supabase.com/docs/guides/functions/schedule-functions), [cron intervals/activation](https://supabase.com/docs/guides/cron/quickstart).


## Calendar rollout addition — 7 October

Worker v6 supports the exact `r5` calendar marker/original-occurrence route and per-job collapse identity. Its retrieved files match both owned bundles. Apply all six calendar migrations matching backend history and run `calendar_reminder_jobs.sql` and `calendar_reminder_bounds.sql` alongside the legacy fixtures. The latter rejects unbounded windows, protects finite counts between folds and checks 20 maximum-count schedules inside four seconds. This does not close whole-account/cohort volume acceptance. [Contract and verified deployment](REMOTE_REMINDER_DELIVERY.md#calendar-occurrence-projection--7-october).

Native delivery is still explicitly false, the native cron inactive and the actual authenticated endpoint returns `disabled`. All existing activation gates remain; calendar support adds no authority to deliver both local and remote notifications independently.

## Calendar cohort budget and timezone upgrades — 7 October

Apply the owned deployed `20261007055145_reminder_calendar_cohort_budget.sql` after the six calendar migrations. The new private catalog contains zone names only; PostgreSQL continues resolving every actual wall time with current tzdata. Queue maintenance refreshes names at most hourly without repeating the catalog scan for each task setting. After updating tzdata, run the service-only `taskfold_private.refresh_reminder_time_zones(true)` before accepting newly added zone names; verify exact membership against `pg_timezone_names`. Clients cannot invoke this helper or access the catalog. Do not activate delivery to exercise it.

Run the owned `supabase/tests/calendar_reminder_cohort.sql` with native dispatch stopped. It rolls back its isolated Auth/device/task/job and temporary reference state, checks private catalog ACL/refresh, 1,283 iterator comparisons and 120 origin comparisons, then reconciles two fixture devices through 160 tasks/3,010 settings. Expect 30 jobs per active device, zero on retry/inactive/foreign owner, and each whole-device RPC below four seconds. The known accepted fixture is not a volume guarantee: retain full-sweep age, due-backlog, provider-outage and operational-owner gates at real enrollment/setting volume. [Deployment and limits](REMOTE_REMINDER_DELIVERY.md#whole-account-calendar-budget--7-october).
