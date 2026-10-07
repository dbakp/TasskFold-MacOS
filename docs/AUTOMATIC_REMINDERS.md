# Automatic reminders for timed tasks

Both native apps own this feature and its release inputs. The default is captured
when a task first gets a valid date **and** time. Notifications settings offer no
automatic reminder, at planned time, and 5, 10, 15, 30, 60, 120 or 1440 minutes
before. A restored integral choice up to 10080 minutes is also shown. Missing
preferences keep the existing at-planned-time default. Date-only tasks retain
their 8 AM planned reminder; disabling the timed default does not disable manual
or date-only reminders, or revoke notification permission.

The choice becomes an ordinary version-1 relative `reminder_specs` row on the
task. Before offsets are negative elapsed minutes. Moving the task moves that
reminder; changing the workspace default does not retime existing task reminders
or snoozes. Recurrence successors retain the relative choice. Duplicates, undo
recreation and create-only restores keep their own reminder rows. Removing a
clock from an existing legacy timed task materializes its at-planned-time choice,
so adding a clock again cannot silently replace it with a newer default.

Explicit manual choices and unsupported rows are preserved. A custom reminder
entered alongside an untouched default keeps both, unless they refer to the same
time; there is one delivery for that time. The private
`taskfold_default_placeholder` extension distinguishes a newly materialized
legacy default from an explicit planned-time choice. Its consumed row preserves
other extension metadata. Manual planned-time edits clear the placeholder. The
captured before-time row uses stable ID
`00000000-0000-4000-8000-000000000002`; at-time/off rows use the existing planned
ID. No reminder signature or task schema version changes.

Quick capture previews use the same policy as Save. First clock edits in a task
editor, pinned-note saves, intents and direct planning patches use that policy.
An implicit default from a stale editor cannot replace a newly synced clock or
reminder choice. Explicit reminder edits continue to use their existing guarded
task editing contract. Notification enablement is separate for each device.

## Preference and deployment contract

`reminder_preferences.current.settings` version 1 gains optional integral
`automatic_before_minutes` in -1...10080: -1 means off, zero means at time, and a
positive value is minutes before. It shares the existing account row with
`snooze_minutes`; owner RLS, account cascade and Realtime remain in force. Future
versions 2...1000 stay opaque and read-only. Malformed supported fields and
oversized documents are rejected before native editing or backup restore.

Ordinary changes call security-invoker `taskfold_set_automatic_reminder`. It uses
an empty search path and a row lock, changes only this field, preserves snooze
and current extension metadata, and rejects future documents. PUBLIC/anonymous
execute is revoked. Responses must confirm the owner, singleton and semantic
choice, with the existing account-incarnation transport fence. The optional
`Mutation.reminderPreferenceField` discriminator survives durable queue encoding;
older queues with no discriminator continue to mean snooze. It is not a database
column. Native replay and acknowledgement also overlay only the selected field,
preserving another device's newer setting and metadata. Create-only restoration
keeps its separate full-document contract.

The additive migration is registered in the existing Taskfold backend as
`20261007101832_automatic_reminder_preferences.sql`. Each repo owns an identical
copy. CLI-created migration files were reconciled to the backend's returned
migration identity to avoid a duplicate apply during release. Stored SQL and
owned SQL have MD5 `6817cef653cfa3552993db907d5b597b`. Apply this migration before
releasing either native app against a different backend. Existing clients can
schedule the ordinary version-1 rows; upgrade both apps to expose the setting.

The primary [Todoist reminder reference](https://www.todoist.com/help/todoist/features/introduction-to-reminders-9PezfU)
describes default reminders for tasks with both date and time. Taskfold now
implements that configurable timed default alongside its existing date-only
behavior. Assigned recipients, remote provider acceptance and sub-day independent
rules remain separate port work.

## Verification scope

Each independent Swift package passes 487 tests, four existing environment
skips, zero failures. New tests cover valid/invalid preference frames, future
fences, metadata preservation, first clock capture, manual choices, duplicate
times, 20-row capacity, recurrence inheritance, legacy clock removal, semantic
offline replay/acknowledgement, HTTP request/response validation and create-only
backup recovery. These package tests run on the Mac host; they are not Mac GUI
or paired native sync evidence.

Actual-role backend automatic and existing snooze fixture suites pass and roll
back. No fixture account remains, no real saved preference is rewritten, and
reminder cron activation remains zero. Security advisor findings are unchanged:
the existing public extension, anonymous/signed-in GraphQL discoverability,
legacy security-definer functions and leaked-password-protection notices remain
baseline work. [Linter guidance](https://supabase.com/docs/guides/database/database-linter)
and [password guidance](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)
define remediation; this migration adds no owner-data bypass. Performance
advisors were also inspected after the additive RPC.

Final native phone/tablet verification and source/build fingerprints are recorded
in the accompanying evidence. Full P0 remains in progress: physical delivery,
paired native online/offline/account/access-revocation/restore, Mac runtime,
remote/APNs delivery and broader widget/accessibility acceptance remain open.


Final iOS 26.5 acceptance passes three flows on iPhone 17 Pro and three on iPad
Pro 11-inch (M5), zero failures/skips. Real capture and UN registry inspection
prove a 09:00 plan schedules the default at 08:45, custom reminders coexist,
turning off the timed default schedules no default for a new task, and changing
the default/relaunching preserves the earlier task and fire instant. Light and
dark largest-text native settings captures are inspected and retained unmodified
in [automatic-reminders/](automatic-reminders/). Largest text uses scrolling; a
viewport does not show every paragraph at once. The DEBUG inspection strip is
hidden for visual-only walks. Its original placement is retained for registry
inspection. The large menu test scrolls its virtualized native option list.

Own unsigned iOS and universal Mac Release app/widget builds pass; own Mac Debug
and isolated iOS Debug app/widget/UI-test targets compile. Each compiled widget
catalogue passes eight configurations, three entities, six enums and completion
metadata. Mac builds do not launch the app. [Machine-readable evidence](automatic-reminder-evidence.json)
and [owned fingerprints](automatic-reminder-inputs-sha256.json) retain scope.
These Simulator/settings checks do not establish Mac runtime, physical alerts,
paired native sync, provider delivery or configured WidgetKit host behavior.
