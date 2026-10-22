# Restore working account removal

Current status (22 October 2026): protocol-2 service and matching migration are deployed. Both apps save a private status proof before deletion. Real iPhone Simulator recovery after deliberate expiry/pruning of its exact synthetic receipt passes on ordinary relaunch. This closes the deleted-account/lost-reply late-expiry gap for proof-bearing commands. Mac runtime/profile, already-expired pre-proof legacy commands, residual-file repair and wider fault/concurrency variants remain open. Earlier candidate/gap sections below are historical; the final status-proof milestone supersedes them only within this scope.

## Confirmed gap — 22 October 2026

Both native `Backend.deleteAccount()` implementations POST to `/functions/v1/delete-account`. The Taskfold project's live Edge Function inventory has no delete-account function; direct management lookup returned Function not found. The app therefore exposes an action whose server implementation is unavailable. This remains a P0 gap, separate from deferred distribution, general older-client rollout and remote-reminder work.

No real account deletion was attempted. Earlier disposable share-test operator cleanup is not acceptance of the app's Delete account action.

## Implemented candidate — not deployed

Each repository independently owns `supabase/functions/delete-account`, migration `20261022174058_account_removal_service.sql`, a local minimal-schema fixture/runner and a hosted rollback-only fixture. Server dependencies are platform APIs only. Server credentials stay in the Edge Function environment; native callers cannot supply an account target, path, admin option or editable-metadata authorization.

New deletion authorization requires verified Auth identity, matching subject/session claims and an active nonexpired, nonbanned database session. Only service_role can begin/read/prepare/complete the removal or read its file manifest. A seven-day hash receipt lets an already authorized irreversible command resume after session revocation or a lost Auth-delete reply. The raw token, profile and task/file contents are never stored in the receipt. Cron/opportunistic pruning bounds retention. This deliberately means revoking a session does not cancel a removal command it already authorized.

Storage cleanup uses the Storage API, canonical owner identity and a narrow owner-null legacy-prefix fallback. Explicit ownership overrides a conflicting account prefix. After begin, restrictive authenticated write policies block uploads/overwrites, including with an unexpired token after user removal. The predicate takes a user-row key-share lock; begin takes an exclusive lock and writes the receipt. A fresh volatile-function snapshot prevents a waiting upload from using a preauthorization receipt view. Trusted service-role writes remain outside these restrictions. Current hosted buckets have versioning disabled; versioned-file removal and a genuinely simultaneous hosted upload/removal race remain unaccepted.

Foreign recurrence children are detached before Auth deletion. Another account's tasks survive an owned project's removal with the existing project/assignment-clearing behavior. Owned reminder-device rows are removed explicitly. Two inviter FKs now use SET NULL so legacy transferred-project membership is preserved; the nested-trigger exception permits only an actual referenced inviter removal. Ordinary nullable-field tampering still fails. Shared comments on surviving tasks retain their body with anonymous attribution. Relevant inviter/member indexes support FK cleanup.

Responses, bodies, paths, batches and transport time are bounded; a partial failure is retryable and never claims completion. Native clients now require an explicit JSON boolean `deleted: true`, rather than accepting any successful HTTP status. A delayed reply from an earlier account or a new sign-in incarnation cannot confirm deletion in the current workspace.

## Verified scope

- Each owned Deno suite: 12 passes, no failures. Includes missing/invalid auth, caller-target rejection, active-session refusal, storage-before-Auth ordering, partial storage failure, eight-batch bound, changed owner/corrupt receipt, pending/complete replay, lost Auth-delete acknowledgement, service outage classification, invalid bucket paths, malformed/oversized/stalled input and error sanitization. HTTP responses are mocked; these are not actual Auth Admin or Storage deletion acceptance.
- Each owned PGlite suite passes its bootstrap, candidate migration, role/session/ownership/FK/storage-policy assertions and final rollback. It covers expired/banned/foreign sessions; authenticated/anonymous inability to access administrative RPCs/receipts; normal outsider uploads; pending upload/update refusal; removed-account refusal after receipt pruning; owner-versus-prefix boundaries; legacy inviter preservation and device cleanup. PGlite is a minimal schema and does not prove the full hosted schema.
- The exact candidate migration plus `account_removal_hosted.sql` passes in one rolled-back hosted transaction. It uses actual task/project/invitation/activity/storage guards and reserved synthetic identities only. It verifies service-only authority, expiry/banning, pending/removed Storage write refusal, surviving tasks/membership/shared conversation and owned project/device removal. Native clients and Storage/Auth HTTP APIs are not exercised by this SQL check. Hosted guards forbid ownership transfer, so the historical transferred-project case is accepted only by the local fixture.
- Each owned Core `AccountTransportTests` suite: 33 passes, no failures/skips. Three new cases cover explicit confirmation, delayed account/session switches and refusal preserving the session. No new full-app UI acceptance is claimed.
- A final independent hosted read confirms zero fixture users/files, no candidate receipt table and no candidate removal RPCs after rollback. No migration/function was persistently installed. There is no test host app running; the OS-managed existing desktop widget extension remains in its normal lifecycle. No Simulator/device setting changed.

Earlier fixture iterations are retained in the artifact logs: local bootstrap initially omitted the invitation trigger and failed its tampering assertion; the original Deno dependency type was too broad for the mock transport; the hosted fixture initially omitted profile IDs, then encountered Storage's direct-delete protection. The corrected hosted fixture uses savepoint rollback of metadata only, never disables triggers, and never directly deletes hosted storage metadata. Formatting was rerun after adding the README. These are fixture/type/format repairs, not earlier passing results.

Security/performance advisors were inspected before committing. Existing warnings include GraphQL metadata exposure, older executable security-definer helpers, pg_net's public extension and disabled leaked-password protection, plus existing RLS/performance notes. This candidate does not claim those baseline findings are resolved. The new service RPCs explicitly revoke client execution; the no-argument own-account Storage predicate is intentionally executable by authenticated callers only. See the [database linter](https://supabase.com/docs/guides/database/database-linter) and [password protection guidance](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

## Native recovery transaction — 22 October 2026

Both apps now persist an account-bound removal command in their own device-only Keychain service before the first destructive request. Snapshot, portable exports, widgets and shared drafts never contain its bearer token. Uncertain-result retries reuse that original authorization without automatic refresh. A definitive endpoint 401 permits conditional renewal only with a freshly verified current session for the same account and server; a different account's session is never substituted. Confirmed progress reaches the Keychain before device erasure, so a crash or cleanup interruption resumes without requiring a deleted Auth user to sign in again. Ordinary sign-out preserves the separate command. Each saved account is attempted independently during recovery.

The destructive confirmation is bound to the account and workspace generation where it opened. Pending deletion fences edits, sync merges, widget actions, Focus/reminders and share publication for that account. A late completion may clean its confirmed account's files, but cannot sign out a different active account. Confirmed removal covers all incarnations of the deleted account; a late accepted sign-in for it is cleared instead of reopening an unusable workspace.

Cleanup writes an account-only cache tombstone under a process/file lock, removes the private cache/queue, and fences delayed cache and recovery-backup writers. It removes that account's private places, consent, handoff state and location receipts, widget actions/projection and sharing drafts; other accounts remain intact. Calendar credentials use their existing serialized vault and cancelled leases. Recovery files and their account-specific Keychain key are removed. Only confirmed cleanup then clears the matching current session and acknowledges the command. Partial failure keeps a visible Retry banner and the remaining recovery command/copies. Normal sign-out still preserves offline work. Confirmation copy now describes retained anonymous shared history and excludes user exports/other devices from erasure promises.

The native Simulator proof exercises actual Store methods, file transactions, Keychain persistence, real AES-GCM recovery-file roundtrips and backup-key deletion, using reserved synthetic accounts and simulated endpoint responses. It checks an interrupted reply/retry, an A → B switch while A's response is held, and an explicit expired-authorization refusal followed by same-account refresh/renewal. It also checks stale confirmations, encrypted outsider recovery/caches/keys, sharing/widget preservation, pending widget privacy, and refusal to reopen a removed account from a late accepted sign-in. The proof uses a fixture-owned sharing directory, not a normal installed App Group or live Auth/Storage server. Final results and exact source/log hashes are in `p0-account-removal-recovery-evidence.json`.

Both owned Core suites pass: iOS 1,303 reported / 13 skipped / 0 failures (1,290 actual), Mac 1,335 / 33 / 0 (1,302 actual). Of these, 45 account/removal cases pass without skips: 37 transport and 8 durable-vault/file tests. The full apps compile. Mac compile acceptance uses signing disabled and is not distribution acceptance.

The isolated Mac runtime check stopped before removal authorization: its copied test entitlement set omitted the Data Protection Keychain identity. Opting into that private identity then correctly required a development provisioning profile unavailable here. `prepare_workflow_ui_test.py --private-keychain` now makes this an explicit opt-in requirement; existing fixture preparation remains unchanged by default. The shipping Mac source already declares its own Keychain group. No weaker credential store or claimed Mac runtime pass substitutes for this gate. See [Apple's app Keychain identity guidance](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps). The user has deferred signing configuration.

Native harness failures are retained: an initial unsigned Simulator build lacked its linked identity; the runner now requires Xcode's embedded identity and verifies real existing team signatures. A raw JSON-byte assertion was replaced with full decoded-cache equality. The runner previously read a stale result before the new app reset; it now removes only the preceding synthetic result before launch, requires the matching scenario and every named check, and retains failed reports. A later B-sharing assertion used a synthetic label that differed from production publication; its fixture now uses the actual account label while still requiring full workspace/draft equality. Initial Core compilation repairs (explicit returns, protocol defaults, SPM source registration and non-Equatable entry comparison) remain in the logs. No failed iteration is counted as a pass.

## Still required before this P0 is complete

1. Review and deploy the matching migration/function together with the current native contract. Gateway JWT verification must be disabled for receipt recovery; new authorization remains verified inside the handler/database. No persistent hosted deployment has occurred.
2. Exercise real HTTP and the actual account confirmation UI with disposable owner/outsider accounts and uploaded file bytes. Inspect Auth sessions, public/private rows and Storage after success, partial failure, lost response, native relaunch and cleanup. SQL/operator deletion, simulated responses and successful builds do not prove these gates.
3. Finish the genuine Mac private-Keychain/native flow when a matching development profile is available, respecting the user's deferred signing work. New confirmation/recovery UI rendering and spoken feedback are not accepted by a Store-only proof.
4. Complete genuinely simultaneous hosted upload/removal and any versioned-storage behavior required if bucket versioning is later enabled. Existing bucket versioning is disabled; local/rollback checks do not prove live byte cleanup or every race.

The remaining Px plan stays in scope. Physical location delivery remains deferred at the user's request; Simulator/Core work continues without claiming real region monitoring. General older-client editing safeguards, remote delivery, release distribution and genuine calendar OAuth remain deferred.

Final evidence refresh: the team-signature-verified Simulator run passed 22 interrupted-retry, 18 late-account-switch and 16 expired-authorization checks. Both final app builds succeeded. The isolated Simulator app was uninstalled and no test host remains running. Removed obsolete owned staging copies and the unsigned Mac compile product (90,262,230 logical bytes); reusable dependencies and evidence remain. A read-only live recheck still found no delete-account endpoint or candidate receipt table.


## Native confirmation and recovery UI — 22 October

The iOS action now opens a scrollable native review with an explicit Cancel control, an irreversible warning and separate removal/retention sections. Cancel and dismissal create no command. Confirmation waits for the review to dismiss, then calls the account/workspace-bound Store transaction. Its result stays on the Store because starting removal deliberately invalidates the previous workspace UI; a network refusal can therefore present its error after Account closes. Other Account errors stay local to their still-present screen.

The recovery card uses concise visible wording and a complete accessibility label, a reachable Retry control and a vertical layout at accessibility text sizes. iOS gives it actual space above the native tab/navigation controllers rather than covering their title/toolbar. Reopened iOS Settings and the independently owned Mac Settings also expose recovery. New destructive confirmations are disabled while that account has a pending removal. Mac's failed deletion sheet offers Retry removal against the already saved command; Close does not imply cancelling that irreversible command.

Final production-UI Simulator acceptance passes five cases without failures/skips: phone Cancel plus full saved-cache preservation and relaunch; explicit failure/visible Retry followed by confirmed cache erasure and sign-out; largest-text dark interrupted removal/relaunch recovery on phone and tablet; actual iOS VoiceOver warning/Delete and recovery/Retry output. Screenshots were visually inspected. An earlier green interaction run still covered the phone title and consumed excessive height at the largest size; its layout was corrected and the five final cases repeated. VoiceOver's prior off state is restored and verified.

This uses an exact isolated DEBUG bundle with reserved fake accounts and a fixed intercepted endpoint. It exercises the actual Account/Root UI, native sheets/alerts, Store, protected files and private Keychain; it does not delete a real account or prove live Auth/Storage responses. Mac's final app build passes with signing disabled; its current private-Keychain/runtime and spoken acceptance remain open. No hosted write occurred. The original server deployment/HTTP and other-account/live-race gates remain required.

`p0-account-removal-ui-evidence.json` records final sources, structured results, actual returned speech, signature checks, inspected captures, failed iterations and cleanup. The speech check establishes the dedicated “This cannot be undone” warning and button roles; returned long-paragraph outputs were partial, so full legal-copy speech is not claimed. The earlier native-recovery evidence remains historical and is superseded only for the scoped iOS UI/layout/speech gates accepted here.

Both isolated Simulator apps/runners were terminated and uninstalled without shutting down the user's already booted Simulators. Removed obsolete staging/unsigned compile products and redundant/unfinished diagnostic bundles (386,741,583 logical bytes); retained final raw results, all exported failed/success speech/screenshots and failed-run logs/summaries. No test host remains running.


## Deployed service and live native acceptance — 22 October

Applied `20261022193804_account_removal_service.sql` once to the shared backend and deployed `delete-account` version 1. Both repos independently own exact matching inputs. The originally generated candidate filename is now renamed to the actual hosted migration version; historical evidence keeps its original source references. The hourly seven-day hash-receipt cleanup job is active. Actual cron execution over seven days has not been observed. Gateway JWT verification remains disabled intentionally: the handler verifies new callers through Auth plus current database sessions, while an already authorized receipt must survive Auth deletion/expiry.

Both native transports send protocol version 1. The endpoint returns HTTP 428 before privileged work for missing/unknown protocol headers, so older bundled clients cannot start deletion without durable current-device cleanup. This compatibility signal is not authorization, and does not reopen or satisfy the deferred general older-client editing safeguards.

Live acceptance created only randomly named, admin-marked `example.invalid` users, actual password sessions, normal projects/invitations and a comment through the existing public comment RPC. Real avatars and attachment bytes were uploaded and read back. The endpoint removed its owner's Auth sessions, tasks and actual bytes, preserved the outsider's independent task exactly and its files byte-for-byte, retained a shared task with project/assignment cleared and kept surviving shared history anonymously. The original token confirmed success again after its Auth account was gone. Caller-supplied target requests failed; the stale access token could not recreate a file. No real account was a fixture.

A controlled real Storage upload against an already pending account began during the same begin-RPC account row lock, waited 4.2 seconds and returned a permission refusal after the transaction completed. Server and HTTP timestamps prove that overlap. This does not prove fresh-snapshot visibility for the first authorization or every full endpoint/upload interleaving. Initial probes were rejected as evidence because status/timing was missing or the request fell outside the lock window; they remain in the reports. A management readiness query could not observe the active transaction. Dispatching the delayed external process before the synchronous management call produced the measured overlap. No temporary public test RPC or weaker policy was added.

The normal isolated iPhone app then signed into another disposable account through its real Auth screen, loaded the live task, opened the production Account review, confirmed deletion, erased its actual private cache and returned to sign-in. A normal no-fixture relaunch stayed signed out with no resurrected cache. Independent Auth/REST/Storage checks after that UI pass confirmed owner removal and the outsider's unchanged task/file/history state. This is one actual native end-to-end happy-path pass, not a simulated response or a Mac/device/distribution pass. Screenshots were visually inspected. Native injected-response Store checks still pass all three scenarios (22/18/16 checks), each requiring the new protocol header. Both apps build; each Core account suite passes 45 cases, each Deno handler suite passes 13 and both renamed local SQL suites pass. Unchanged wider Core suites were not rerun.

The first real setup hit the existing no-direct-comment-write policy. Its two disposable users were cleaned up, and subsequent cohorts used `taskfold_write_comment`; no policy was relaxed. An initial rollback-composition quoting error and a reserved test-CTE name were orchestration errors, not migration fixes. All failed reports remain available.

Security advisors retain the six existing warning groups. A new informational RLS-without-policy finding is expected for the unexposed, service-only receipt table: anonymous/authenticated read and administrative execution remain revoked; service-role access and the authenticated own-account Storage predicate are deliberate. No permissive client receipt policy was added. Baseline findings are not claimed fixed. See the [RLS linter guidance](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy). Current function-auth and Auth-delete documentation/changelog were checked before deployment.

Final independent database inspection shows zero Auth users, sessions, profiles, projects, tasks or files for all ten disposable identities across the five cohorts, and zero pending receipts. Four completed synthetic hash receipts remain under the normal seven-day retention policy; they contain no raw authorization/content. All temporary server keys, passwords and session fixture files are removed. The isolated app/runner are terminated and uninstalled; obsolete Mac staging/compile products are pruned (80,683,260 logical bytes). Existing user applications, real tasks and already booted Simulator settings are preserved.

Still required: genuine Mac profile/private-Keychain/runtime acceptance, real native network interruption/lost-response recovery variants, first-authorization/full HTTP concurrent-upload variants and versioned Storage if enabled. Remote delivery, distribution, general older-client editing safeguards, provider registration and physical location testing remain user-deferred. These results do not finish the remaining Px backlog.


## Genuine HTTP lost-acknowledgement recovery — 22 October

Both repositories independently own a DEBUG-only fault hook. Only the exact isolated test app, existing project origin, matching current generated account and an explicit test flag can discard the first acknowledgement. The actual fixed HTTPS transport must already have received and validated the deployed service’s success before the hook raises a connection-lost error. The Store therefore retains its unconfirmed private command and complete device cache, while the real server has already removed the account. No fake endpoint or success response is substituted. Release and Swift Package targets omit the hook. Its bounded diagnostic contains only account/origin, counts and authorization hashes; credentials remain in the private native vault.

Two separate actual iPhone Simulator cases pass. One uses the visible Retry action in the same process. The other terminates the app and launches it with ordinary appearance arguments only: no test sign-in, account, seed, recovery producer or fault flag. Both receive a second genuine success response with the identical original authorization hash, finish device erasure, remove the cache and remain signed out after another ordinary relaunch. Each has exactly two confirmed server responses and one discarded acknowledgement. The existing Core account/removal suites pass 45 cases per repo, and both full apps build. Mac runtime/private-Keychain acceptance is still deferred with signing.

A separately running native-pause observer checks real Auth/REST/Storage before either native retry begins. It verifies that the owner’s account and actual file bytes are already absent, its old Auth session cannot read a user or recreate a file, and the outsider’s task/file/history state stays correct. Only then does it release the UI test. The native test compares the entire saved cache both before and after this pause, proving that confirmed server removal precedes remaining device-copy erasure. Independent post-recovery checks pass again. Only four generated disposable identities are used and all are cleaned up.

The seven-day boundary is now stated in both native review screens. A final native Cancel/relaunch/cache-preservation check passes with the updated iOS copy, and its screenshot is visually inspected. The two genuine recovery cases preceded only that wording change; their transport/Store/test code is unchanged. The safe explicit fallback for a still-unconfirmed command after receipt expiry is **not implemented**: a server-deleted account cannot sign in again, and current code retains its local copies rather than guessing that deletion succeeded. This is a newly explicit P0 recovery gap. It must not be hidden by the successful within-window recovery checks.

The normal hourly receipt job is observed running at 20:11:00 UTC, succeeding with DELETE 0. A completed synthetic receipt was then deliberately aged at 20:11:03—after that tick. Its recovery grant became unavailable immediately. A separately guarded manual execution of the exact retention predicate removed that expired test row; no nonfixture expired row was allowed into that operation. This proves the real job ran and the expiry/maintenance behavior separately, not that this expired row was removed by the natural tick or that seven actual days elapsed. The other new completed receipt matches the native authorization hash and expires normally. The job definition/schedule and service code were not changed.

`p0-account-removal-lost-reply-evidence.json` records real UI summaries, source/build hashes, paused/post-recovery server checks, diagnostics, retention scope and cleanup. All private credential files and isolated app/runner sessions are removed; obsolete Mac staging/compile products are pruned (80,720,839 logical bytes). Earlier deployment/candidate evidence remains historical. Wider P0/Px and all user deferrals remain open.


## Status-only proof and late-expiry recovery — 22 October

Protocol 2 separates preparation from destructive execution. Preparation verifies
an existing receipt or real current Auth/session, then issues an origin/account
bound HMAC status-only proof. Each Store durably saves it to the private removal
Keychain vault before execution. A failed secure save prevents execution. Neither
proof nor bearer belongs in snapshots, exported backups, widgets or diagnostics.
Execution still needs a current authorization receipt or verified same-account
Auth/session. The proof never grants permission to delete an existing account.

After the seven-day receipt expires/prunes, a valid proof can confirm only that
Auth and canonical/legacy-owned Storage metadata are absent. Key-service outages
remain retryable; revoked/invalid proofs cannot confirm. Signing keys are global,
service-only random material, independent of API-key rotation; retain inactive
keys for old proofs unless explicitly revoked. The service keeps no new permanent
per-account tombstone. Client roles cannot read keys or invoke the absence RPC.

New local commands are version 2. Confirmed version-1 commands can finish their
already-authorized local cleanup without network. Unconfirmed legacy commands
prepare while a valid receipt or same-account login is available. Already-expired
pre-proof commands whose Auth is gone remain unprovable; owned residual file
metadata after receipt expiry requires administrative repair. These paths keep
local copies rather than guessing. Losing/revoking signing keys also invalidates
proofs; device Keychain removal is outside durable recovery guarantees.

The hosted function is version 2 (gateway JWT check stays off for deleted-account
recovery; handler/database authorization is mandatory). Migration
`20261022203333_account_removal_status_proofs.sql` is shared-backend applied once
and independently owned by both repos. Local schema tests use real pgcrypto and
check privilege denial, rotation/revocation and absence rules. Each Core suite
passes 50 account/removal cases, including secure-save failure, stale confirmation,
legacy decode and invalid proofs. Each Deno suite passes 20 cases. Both full apps
build. Three isolated Simulator Store scenarios pass 22/18/16 checks.

A real native lost-success-reply case retained the full cache while an independent
observer verified server deletion and outsider preservation. A guarded operation
aged and pruned only that exact completed synthetic receipt at 20:35:56 UTC; the
status RPC returned no receipt. Ordinary no-fixture relaunch then confirmed via
the private proof and erased local copies, with the same original authorization
and no reauthentication. This deliberately manipulates the test receipt; it is
not seven elapsed days or a claim that cron pruned it. Current-scope evidence and
remaining acceptance are in `p0-account-removal-status-proof-evidence.json`.
