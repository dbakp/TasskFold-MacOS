# Remote reminder registration foundation

Native reminder delivery currently uses local notifications. The private device registry and native transport contract below are implemented, but the apps do not yet register automatically or offer remote delivery. An enabled registry receipt alone cannot establish a working provider or notification pipeline. The complete [remote delivery plan](REMINDERS.md#remote-delivery-implementation-plan) remains required.

## Ownership and API

Each native repository owns its `ReminderDevices.swift`, migrations, SQL fixtures and Edge Function sources. Neither build reads the sibling repository. The deployed migrations are `20261006112647_reminder_device_bindings.sql` and `20261006112835_reminder_device_direct_access_policy.sql`.

APNs addresses live in `taskfold_private.reminder_devices`, outside the exposed API schema. Clients have no direct table privileges, and an explicit deny policy applies to anonymous and authenticated roles. Public RPC wrappers use `SECURITY INVOKER`; privileged writers remain in the private schema with an empty search path. [Supabase function security guidance](https://supabase.com/docs/guides/database/functions) and [RLS guidance](https://supabase.com/docs/guides/database/postgres/row-level-security) describe these boundaries.

| RPC | Authentication and effect |
| --- | --- |
| `taskfold_register_reminder_device` | Requires a signed-in JWT, matching existing live Auth session and installation capability. Derives the owner/session on the server. Can enroll, update, activate or rebind only that installation. |
| `taskfold_retire_reminder_device` | Requires the installation capability and a newer revision. Can run after local sign-out. Anonymous callers cannot enroll, activate, read addresses or discover other installations. |

The binding contains exactly `platform`, `bundle`, `environment`, `token`, `time_zone`, `permission` and `enabled`. iOS uses `com.dbakp.taskfold`; Mac uses `com.dbakp.taskfold.mac`. Environment is development or production; permission is authorized, provisional or denied. Denied permission cannot accompany enabled delivery. Tokens are opaque even-length lowercase hex, bounded to 512 bytes; time zones must be recognized. Platform/bundle combinations and extra fields are rejected.

Receipts contain only version, installation ID, revision, account, registered/retired state, enabled flag and lease expiry. They exclude token, capability, hash, Auth-session ID and task content. Registration verifies that the JWT session still exists and has not expired. Deleting its Auth session or account clears the binding/address and retains the installation fence.

## Ordering, retry and local storage

An installation has a random UUID, a 256-bit random capability and a monotonically increasing revision bounded to JavaScript's safe integer range. The server stores only the capability hash. Native storage uses a separate `AfterFirstUnlockThisDeviceOnly` Keychain item for the capability and revision. Neither enters task records, widget snapshots or exported backups. Corrupt or unreadable secure storage fails closed rather than silently replacing an unknown installation.

Reserve and securely persist the next revision before dispatch. Retry a lost acknowledgement with the exact same command. Identical registration retries return the original receipt without renewing its lease; changed payloads at the same revision and older commands fail with `TASKFOLD_DEVICE_CONFLICT`. Native HTTP transport freezes the current account/session generation; responses from account switching or same-account reentry are rejected.

First enrollment is always inactive. A later acknowledged revision can activate it. Retirement clears owner, session and token. Retiring an unknown UUID returns a neutral receipt without creating anonymous rows; a late first enrollment can therefore only be inactive. The future runtime coordinator must finish enrollment and recheck the current opt-in/session before activation. These primitives are not yet wired to lifecycle callbacks, settings or sign-out.

Bindings expire after 30 days. There are at most 32 registered bindings per owner, including inactive bindings. A push address is unique within platform/bundle/environment; duplicates are rejected rather than silently taking over another installation. Expiry cleanup, reinstall/duplicate-address recovery, user device-management UI and periodic renewal are still required. Expired rows currently count toward the registration quota until retired; a future worker must enforce expiry immediately before dispatch.

Apple requires obtaining the current token through registration each launch and keeping provider credentials on the server. The native vault deliberately does not cache the token. Production callback wiring, platform-specific APNs entitlements and sandbox/production provider routing remain unimplemented. See [registering with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns) and [remote notification server setup](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server).

## Existing web cron

Each repo now owns `supabase/functions/check-due-tasks/{index.ts,handler.ts,handler_test.ts}`. Deployed version 13 matches these sources. Missing, empty, oversized or wrong `x-cron-secret` values fail before any database/provider request; valid requests must use POST. JWT verification remains off because this existing service endpoint authenticates its custom cron secret. No task titles, subscription addresses, provider response bodies or exception text are logged or returned. Network response bodies are consumed or discarded.

This preserves the existing web worker's UTC due-minute query, one OneSignal subscription per profile, notification opt-out and task-level `notification_sent_at`. It is not the future versioned native occurrence worker and does not establish APNs, multi-reminder retry/cancellation or exactly-once delivery. The existing minute cron remains enabled. Earlier version 12 logged two successful cron requests and the two rejected authentication smokes; final version 13's source was retrieved and compared, and its unauthenticated POST returned 401. No manual authenticated dispatch to real recipients was used for verification.

## Reminder scene handoff

Both native apps now retain workspace ID, workspace generation, task ID, reminder ID and current schedule signature between notification validation and scene presentation. The scene revalidates the packet before opening the editor. Leaving/reentering even the same account, completion/reopen, removal, changed schedule, inaccessible cache or disabled delivery invalidates it. Complete/Snooze/Tomorrow keep their existing guarded action paths.

The two iPhone route walks inject held validated packets through an isolated Debug harness and exercise actual scene/editor presentation. They do not establish killed-process or cold system-notification routing. That runtime acceptance remains open.

## Verification and remaining work

- Both Debug and optimized core suites: 368 tests, four optional integration skips, zero failures per repository/configuration. Device contract/storage/receipt tests, held HTTP responses and route incarnation/signature tests are included.
- Real disposable Auth sessions: one native HTTP integration test passes in each repo. Coverage includes inactive enrollment, exact acknowledgement retry, same-owner session replacement, account rebind, foreign proof denial, anonymous retirement and stale revisions. Fixture users/devices were removed; final counts are zero. No real APNs address or provider request was used.
- Rolled-back SQL fixtures pass before and after migrations: direct table/anonymous enrollment denial, strict binding validation, ordering/proof checks, duplicate address, 32-device quota, retirement retry/unknown IDs and Auth-session deletion. Account deletion is handled by the schema; a separate account-deletion acceptance walk has not been executed here.
- Five fake-transport Deno tests pass in each repo without network/environment permissions; entrypoint type checking passes. Missing/wrong authentication, configuration/method checks, UTC query, opt-out, provider rejection, accepted marking and error privacy are covered.
- iPhone 17 Pro/iOS 26.5: three executed passes, zero failures/skips in `/tmp/taskfold-reminder-route-ios.xcresult`: current held route opens its editor, same-account workspace reentry rejects it, and the existing system permission/disable regression passes.
- Independent iOS Release app/widget and universal arm64/x86_64 Mac Release app/widget builds pass. Signed Mac UI-test compilation passes. Mac runtime remains unexecuted on the locked desktop; no installed Mac app was replaced.

Security/performance advisors were inspected. The reminder table's initial no-policy finding was resolved by the explicit deny policy migration. Its unused expiry index is intentional preparation for lease scanning on the currently empty registry. Existing unrelated findings remain; this is not a project-wide security audit.

Remaining delivery work includes native callback/coordinator/opt-in/status and sign-out integration; expiry/token/reinstall recovery; canonical occurrence/signature projection; leased jobs/retries/access revalidation; APNs/email provider configuration and delivery; local/remote authority and deduplication; staged rollout/operations; and paired/offline, cold/closed-app, physical iPhone and signed Mac acceptance. No complete remote-delivery claim is made at this checkpoint.
