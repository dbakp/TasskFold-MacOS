# Synchronized reminder snooze preferences

Implemented independently in the iOS and macOS repositories on 7 October 2026. This closes the configurable local snooze implementation gap; full P0 acceptance remains in progress.

## User behavior

Notifications settings offer 5, 15, and 30 minutes, 1, 2, and 4 hours, and 24 hours. A restored supported choice between 1 and 1440 minutes is also shown. Missing preferences retain the existing one-hour default. The delay is elapsed time from the notification action; 24 hours can differ from the next local day's same clock time across daylight-saving changes. Move to tomorrow remains a separate action.

The choice is saved durably in the current workspace before the UI confirms it. Signed-in workspaces queue and sync it; local workspaces retain it locally. Notification permission and delivery enablement remain per device. Changing the preference does not retime an existing snooze. Notification action identifiers carry the displayed delay, so a later settings edit cannot silently change a tapped action. Already-delivered legacy one-hour actions still mean one hour. Malformed or out-of-range snooze actions are ignored.

The native menu row has a minimum 44-point target, a readable selected value and a wrapping accessibility layout. Unsupported settings remain read-only and preserved. A settings view captures the workspace incarnation; reopen Notifications after switching workspaces before editing.

## Data and release contract

Both repositories own their sources, SQL migration, fixtures and release inputs. Deploy `20261007065249_reminder_snooze_preferences.sql` before releasing either native app. The additive migration is applied to the existing Taskfold backend. Stored migration SQL matches the owned source after normalization of trailing whitespace.

`reminder_preferences` has one `current` row per account, a versioned JSON settings document, a composite primary key, owner-only RLS, explicit anonymous denial, an account-delete cascade and Realtime publication. Version 1 stores integral `snooze_minutes` in 1...1440. Opaque future versions 2...1000 are accepted within the server's 8192-byte canonical JSON limit. Native compact encoding disables slash escaping and accepts up to 8192 bytes; malformed numeric frames and oversized documents are rejected.

Ordinary preference changes call the authenticated security-invoker `taskfold_set_reminder_snooze` RPC. It locks the current row and updates only the delay, preserving extension metadata last written by another device. The RPC rejects a future settings version instead of downgrading it. Native responses must confirm the intended owner, singleton and delay; account reentry invalidates in-flight responses. Offline choices remain queued when the server cannot confirm them.

Portable backups include the row, preserve opaque supported-size future settings and retain the `current` identity when restoring to another account. Create-only restore retry does not replace an existing preference. Existing older backups without this table remain readable. Older app releases keep working with their existing tables and default snooze, but do not expose this feature and may reject new backups containing the new table. Upgrade both native apps for snooze feature parity and new-backup recovery. Existing older readers are not claimed to support this addition.

## Verification and remaining acceptance

- Each app-owned core suite: 477 tests, four optional live-account tests skipped, zero failures. Ten added tests cover action/document validation, size compatibility, account ownership, exact elapsed scheduler delays and restart preservation, malformed-delay no-op, cross-account backup/retry, and guarded semantic HTTP transport including account reentry. Scheduler tests use the native scheduler with an injected notification center; they do not prove OS delivery.
- Each owned `supabase/tests/reminder_preferences.sql` passes against the deployed schema under actual authenticated owner and outsider roles. The fixtures cover row isolation, invalid frames/delays, metadata preservation, composite retry, ownership-transfer denial, future-version fences, integral decimal versions, size limits, anonymous grants, Realtime and account-delete cleanup. The prototype and final fixtures roll back. A separate check confirms zero fixture accounts/preferences and no active native dispatch cron.
- Final unsigned iOS Simulator and universal Mac Release app/widget builds pass. Debug app/widget/UI-test-target builds pass on both platforms; the Mac test target is compiled only. Each owned catalogue verifier confirms eight widget configurations, three entities, six enums and completion metadata. The universal Mac executable contains x86_64 and arm64. Installed widgets and signed distribution remain separate gates.
- Four final iOS 26.5 user walks pass: iPhone 17 Pro and iPad Pro 11-inch (M5), each in light mode and dark largest text. They verify reachable controls, a minimum 44-point target, changing to 15 minutes/2 hours and retention after relaunch. Screenshots were visually inspected and retain readable neutral values. Native settings tests exercise the real Store/cache; they do not establish paired-account sync or OS notification action delivery. Result bundles: `/tmp/taskfold-snooze-phone-neutral.xcresult` and `/tmp/taskfold-snooze-ipad-neutral.xcresult`.

The security advisor adds one expected authenticated GraphQL schema-discovery finding for this readable account table (14 to 15). Anonymous schema discovery stays at six; no new missing-RLS or mutable-search-path finding is introduced. Actual owner/outsider tests demonstrate row isolation; schema discovery does not grant foreign row access. Existing security findings remain. See [authenticated schema discovery remediation](https://supabase.com/docs/guides/database/database-linter?lint=0027_pg_graphql_authenticated_table_exposed). Performance finding counts remain unchanged from the immediate baseline.

Paired native online/offline switching, notification-category/OS action and physical/background delivery, Mac runtime and provider acceptance remain required. No APNs delivery or remote scheduler activation is claimed by these tests.
