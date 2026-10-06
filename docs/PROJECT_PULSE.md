# Project pulse

Both native repositories own a Project pulse screen and compatible activity contracts independently. Open it from iPhone Browse, a project's Task options, or the Mac toolbar. Choose a project to see current completion, tasks needing attention and its recorded timeline. Small, medium and large Project pulse widgets now offer per-instance project selection, appearance and name privacy.

## What the numbers mean

“1 of 3 completed” counts unique current project task occurrences, including completed tasks. Embedded checklist items are excluded. Adding, removing or moving tasks changes the denominator. This is current scope, rather than a historical velocity or project health score.

The last seven days include today and the preceding six local Gregorian calendar days. The screen names the window and device time zone. Completion/reopen **events** count actual transitions: completing, reopening and completing one task produces two completion events, one reopen event and one currently completed task. Created copies that are already completed do not manufacture old completion events. The recorded server receipt time determines the window; a completion's chosen time is preserved separately. DST changes do not turn this into a fixed 168-hour window.

Needs attention offers open tasks planned before today or with deadlines before the end of the next seven days, including overdue deadlines. At most five rows appear, with a remaining count. Tapping opens the existing task editor. No automatic completion or rescheduling occurs.

## Honest history and access

History begins at the deployed recording epoch. Earlier work has no recorded timeline, and existing work is not backfilled as if newly completed. A workspace without a loaded epoch shows an explicit unavailable/start-recording message, rather than invented zero-event coverage. Malformed activity suppresses recent counts and requests refresh. Local work records actual saved mutations atomically in the device snapshot; signed-in work displays server-confirmed events after sync and explains pending task changes.

Each server event contains an immutable sequence/UUID, task/owner/actor identifiers, server receipt and effective timestamps, completion version, transition kinds and ten planning/completion fields before/after. It contains no task title, notes, comments, attachments or credentials. Event rows survive task deletion. Titles in the screen come from currently readable tasks; unavailable tasks have a neutral label. Changes to private title/notes or delivery bookkeeping alone produce no event. A single combined move/reschedule has one event with both kinds.

Authenticated clients have SELECT only; task triggers write the history after final completion normalization. Anonymous reads and all client ledger writes are denied. Owner/member reads check the task's current project access and both recorded scopes. Leaving a shared project removes member access, including a task originally created by that member. Shared-to-private moves do not disclose predecessor/successor planning metadata. Account deletion cascades without recreating history; authorized project deletion may record SET NULL moves. Fetches use strictly advancing sequence keysets in pages of 500 and retain the captured account generation across awaits/retries. Workspace changes close the screen; a removed/revoked selected project shows unavailable rather than silently switching to another.

## Backup and deployment

Portable backups retain validated activity as an archive. Restore does not replay ledger rows or its epoch as new history; the preview explains that restored task copies start their own activity. Duplicate event IDs and malformed transition states are rejected. Existing overall 50,000-record and file-size limits still apply.

Each repository owns the deployed migrations `20261006100647_task_activity_history.sql` and `20261006100920_task_activity_cascade_authorization.sql`, the rolled-back SQL fixture `supabase/tests/task_activity.sql`, native model/transport tests and its platform screen wiring. The second migration fixes a real integration finding: rechecking a deleted project's access inside the trigger blocked an already-authorized foreign-key cascade. The final trigger trusts the authorized task mutation and keeps read access guarded separately. No other repository is a build dependency.

The implementation follows official [database trigger](https://supabase.com/docs/guides/database/postgres/triggers), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) and [database function](https://supabase.com/docs/guides/database/functions) guidance. The public Supabase changelog was checked before migration. Existing unrelated security/performance findings are not resolved by this feature.

## Widgets

Edit a Project pulse widget to choose its project, Default/Rose/Lavender/Mint appearance, and whether project/task names are hidden. Small shows current completed/total and the attention count. Medium adds recorded completion/reopen events, seven-day date window/recording start and one attention title. Large adds additions/moves, up to three attention titles and recording-coverage explanation. Hidden names preserve useful counts. Every tap opens the native current Project pulse screen; no widget task mutation is performed.

The version-1 pulse cache has stable account/project identity, current unique task counts and eight precomputed local-day summaries. Each daily summary uses the same native seven-day and attention semantics. Unreceived/future-clock events are excluded; tomorrow drops old events without inventing future changes. At local midnight, an exact timeline entry updates the window and attention reading; at 24 hours from publication it becomes Refresh. Time-zone changes require a fresh app publication. Legacy, unreadable, malformed or foreign-account projections cannot present fresh project counts. Missing history is stated separately from current task completion.

The extension receives at most 2,048 deterministically ordered project cards, 160-character/1,000-byte project names and three 120-character/800-byte attention titles per day. Counts are validated to one million; unique IDs and eight valid day keys are required. The app retains its whole project catalogue. An omitted selection yields Refresh rather than falsely claiming deletion or substituting another project. No full activity rows, notes, actor identities, credentials or executable commands appear in this new cache. Widget settings are local to each instance; project/task/history data remains account-synchronized.

Selection IDs encode the account and stable project ID. Rename retains the choice; deleted/revoked choices remain Unavailable, and unresolved entity queries retain a neutral label for their old identity. Stale/foreign taps preserve the encoded target account and are rejected by the native handler. A missing project opens its explicit unavailable screen. The implementation follows Apple's [configurable widget guidance](https://developer.apple.com/documentation/widgetkit/making-a-configurable-widget) and [AppIntentConfiguration contract](https://developer.apple.com/documentation/widgetkit/appintentconfiguration).

## Remaining acceptance

Installed configuration/multiple-host/refresh and live privacy/account-change acceptance remain to verify. Native Mac interaction, physical/iPad, paired/offline/account revocation/reentry/restore and provisioned distribution remain open. Current Core/SQL/iPhone fixture evidence is recorded in the platform validation tracker; it does not establish these broader requirements or completion of the full P0 objective.
