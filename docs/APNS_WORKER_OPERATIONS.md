# Native reminder worker operations

The native worker is deployed with delivery disabled. Each native repository independently owns the identical backend contract and worker release files. Deploy the reviewed version from one repo and synchronize the exact source/version into the other; do not deploy competing versions from separate native releases. Never place APNs keys, service keys, installation capabilities or device addresses in app/widget bundles, task records, backups, logs or repository files.

## Current state

`dispatch-reminders` uses custom service authentication (`verify_jwt=false`, checked by the handler). Its dedicated 256-bit cron secret is configured; the delivery switch is explicitly false. Retrieved deployment v3 matches the final owned source. Updating secrets restarted the initial deployment; authenticated smoke ran on v2 before the final diagnostics/time-budget refinement. The existing `check-due-tasks` v13 and web minute cron remain unchanged. No native scheduler or APNs credential has been added. HTTP smoke verifies anonymous POST 401, authenticated GET 405 and authenticated POST 200 with `{ "status": "disabled" }`. Registry and queue are empty after fixture rollback.

## Required private configuration

| Secret | Meaning |
| --- | --- |
| `TASKFOLD_REMINDER_CRON_SECRET` | A distinct random service secret of 32–512 characters. Invoke using `x-cron-secret`; never reuse a public/client key. |
| `TASKFOLD_APNS_DELIVERY_ENABLED` | Only exact `true` arms dispatch. Keep `false` until every rollout gate below is accepted. |
| `TASKFOLD_APNS_KEYS` | JSON array of one to four explicitly scoped signing entries: `platform`, `environment`, `bundle`, `teamID`, `keyID`, `privateKey`. `privateKey` is the PKCS#8 .p8 PEM, stored solely in backend secrets. |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Platform-provided backend connection; service key never reaches native clients. |

Allowed pairs are iOS / `com.dbakp.taskfold` and macOS / `com.dbakp.taskfold.mac`, each with `development` or `production`. Keys must authorize the exact topic and environment in Apple Developer. Duplicate scopes, invalid IDs/PEM and missing HTTP/2 capability fail closed before any queue claim. The worker does not infer production from Debug/Release, borrow another environment's credential or fall back to HTTP/1.1. Native registration must read its signed entitlement and fresh token instead of guessing that environment. Use the Supabase secret UI or CLI `secrets set --env-file` with a private temporary file; keep values out of shell arguments/output and delete that file afterward.

## Bounded invocation and scheduling

Authenticated **POST** accepts only optional `?after=<lowercase UUID>`. It maintains expired bindings/terminal receipts, reads an ordered page of up to 20 device IDs, reconciles each device and claims up to four jobs sequentially. Provider and database calls have eight-/five-second timeouts. No request body is required. Extra/duplicate/malformed query parameters return 400. Counts and the bounded aggregate `diagnostics` codes (accepted, retry, unregistered, payload, provider_configuration, transport) contain no task titles, tokens, notes, addresses or provider exception/body text.

A successful response reports `processed` or `paused`, aggregate counts and `nextCursor`. Persist a non-null cursor only after receiving the response; null means restart from the beginning on the next sweep. A paused response retains the preceding fully processed device so unfinished work is revisited. An empty/exhausted page cycles to the start. Four-job device caps are intentional: drain further due work on later sweeps. A 502 or lost response retries from the prior cursor. Do not attach a static one-minute request that always starts at null: once more than 20 devices enroll, it can starve later IDs. A production scheduler needs one durable, leased cursor coordinator, bounded sweep latency within the one-hour catch-up window and monitoring before activation. Concurrent workers cannot share a job lease, but this does not make cursor progress or provider acceptance exactly-once.

| Response/receipt | Operational meaning |
| --- | --- |
| 401 / 405 / 400 | Fix service authorization, method or cursor. No work is dispatched. |
| 200 `disabled` | Switch off. No database/provider request. |
| 503 | Missing/invalid provider/backend configuration. No claim. |
| 200 `paused`, retry count | Provider/transport/configuration failure or remaining time budget. Revisit previous cursor after the appropriate delay. |
| `receiptRejected` | Task/access/account/device/lease changed while sending. Never treat the attempted provider request as a current confirmed send. |
| 502 | Database/validation failure; private details withheld. An accepted provider request may have lost its acknowledgement. Do not immediately resend that occurrence manually. |

The queue contains bounded outcomes only. Use service-only aggregate state/outcome/age/attempt metrics, not raw bindings or task content, for diagnostics. Alert on growing due backlog, failed/exhausted outcomes, repeated paused/503/502 responses and registration failures. Signing/topic errors halt a batch and use a 15-minute delay; fix credentials instead of retiring devices. Known `BadDeviceToken`, `DeviceTokenNotForTopic`, `Unregistered` and `ExpiredToken` responses retire the current fenced binding; the app must obtain a fresh registration. Unknown 4xx responses halt without retiring or permanently losing every affected event. APNs 5xx waits at least 15 minutes. Retry-After is bounded to one hour and cannot shorten the database's exponential backoff. Eight attempts and one-hour catch-up expiry remain the maximums.

## Activation and rollback gates

1. Accept the independently implemented inactive native lifecycle on final provisioned binaries: fresh-token callbacks, signed environment/topic, permission/time-zone/token changes, account-incarnation fencing, secure revision persistence and proof-based retirement on sign-out. Implement explicit device opt-in after delivery authority is accepted. Core fixtures/iPhone local UI pass; actual signed-token, physical and Mac runtime acceptance remains. Keep native remote activation unavailable until these gates pass. See [lifecycle contract](REMOTE_REMINDER_DELIVERY.md#inactive-native-registration-lifecycle--6-october).
2. Implement one delivery authority per event/device and reconcile pending local requests. Preserve local snoozes/Focus as intended; verify offline/lease expiry/reconnect behavior. Stable APNs IDs/collapse do not prove deduplication. Test ambiguous provider acceptance, delayed stale notifications and current-state action validation.
3. Configure sandbox credentials privately, verify hosted HTTP/2 execution, real APNs acceptance and a physical iPhone's foreground/background/terminated delivery. Test reschedule/complete/delete/restore/travel/permission/account switches, invalid token and downtime. Separately verify signed Mac closed-app delivery when desktop testing is available.
4. Implement and test the durable scheduler cursor coordinator and safe sweep retry. Monitor only private service aggregates and establish an operational owner. Adopt an explicit recipient policy before collaborator-wide reminders; the current queue delivers owner occurrences only.
5. Enable a small accepted cohort, compare actual OS display/actions with queue receipts, then expand. Do not remove the legacy web worker or enable both local and remote delivery independently for one device occurrence. Production signing/release and physical acceptance are separate gates.

Rollback by setting `TASKFOLD_APNS_DELIVERY_ENABLED=false` and stopping the native cursor scheduler, then have the apps explicitly retire/disable remote bindings and restore the verified local authority path. Already accepted APNs notifications cannot be recalled. Do not replay failed/obsolete jobs, reset generations or remove receipt/installation fences to recover delivery.

## Reproducible checks

Run `Scripts/test_reminder_worker.sh` in either repo. It uses no credentials or network permissions: 18 native provider/worker fixtures plus five web compatibility fixtures and both entrypoint typechecks. The signing test creates an ephemeral P-256 key and verifies the resulting JWT, without any production key. Run `supabase/tests/reminder_jobs.sql` against an isolated accepted backend using actual client/service roles; it wraps all Auth/device/task fixtures in a transaction and rolls them back. Both deployed migration files must match backend history before rollout. Passing these checks does not prove APNs or OS delivery.

Reference contracts: [Apple request/HTTP2 headers](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns), [Apple token signing/refresh](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns), [Apple responses/retry guidance](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns), [Deno HTTP clients](https://docs.deno.com/api/deno/fetch/), [Supabase service-function authentication](https://supabase.com/docs/guides/functions/auth).
