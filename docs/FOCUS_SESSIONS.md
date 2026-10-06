# Focus sessions

Open **Browse → Focus session** on iPhone, or **Focus session** in the Mac task toolbar. Choose an open task and 1–180 minutes. Pause, resume, end, or start a new session. Reopening retains the current task and duration as the next-session defaults. Replacing an unfinished timer asks for confirmation. Finishing the timer leaves the task open; task completion remains a separate decision.

The native screen uses the app's accent, wrapping task titles, a rounded timer card and a scrollable layout. iPhone duration and session buttons have 44-point minimum targets. A missing or completed task can still have its session ended; it cannot be resumed from the native controls. No title or task content is duplicated into the session record.

## Durable clock and sync

Both repositories independently own the same version of `FocusSession.swift`, transport, restore rules and native screen. Each account has one `focus_sessions` row with `id: current`. Its `state` contains a session UUID, task UUID, duration, accumulated elapsed milliseconds, UTC start/change timestamps, optional running timestamp and running/paused/stopped status. Remaining time is derived from timestamps, independent of local tick counts, time zone, process lifetime and redraw frequency. Pause accumulates elapsed time; resume starts a new running interval. A backward device clock cannot decrease accumulated time or command timestamps. Elapsed time is capped at the chosen duration.

Every command has a new action UUID and a baseline containing the prior revision and action UUID. The authenticated, security-invoker `taskfold_set_focus_session` RPC creates/locks the account's slot, verifies that baseline, and advances its revision. An exact retry acknowledges the original action without advancing again. Stop/clear retains the revision slot; authenticated clients cannot delete it and reset the counter. Direct updates also require a new revision and action. The server checks task visibility/open status on start and resume; paused checkpoints may refer to a completed task. Switching tasks requires a new session UUID.

The existing account-bound cache and durable queue save commands before sync. REST fetch and Realtime subscribe to the session table. Account/generation guards reject stale screens. Timer commands do not enter ordinary task Undo history. Sync conflicts show **This device** and **Synced session**. Use synced discards the dependent timer-command chain; Keep this device rebases its final state as one guarded action. Both preserve unrelated queued work. A failed initial start whose task disappeared can be reviewed against an empty synced slot.

Authenticated transport freezes the account and session generation across requests, 401 retries and joined token refreshes. Accepting a different session invalidates earlier refresh work; a late response cannot overwrite the newly accepted account. Sync passes its captured workspace account to every queued mutation, including edits to shared tasks. Deterministic held-response tests cover these races without contacting real accounts. These guards do not replace native paired-device/account-switch acceptance.

The screen captures the session and its revision together before rendering its controls. A stale button cannot borrow a newer session's revision. The server can reject a second conflict after review; it is not a last-write-wins timer.

## Backups and deployment

Portable exports freeze a running timer as a paused checkpoint at export time. Restore remaps the task and session identities, preserves elapsed time, and uses the target account's current revision. It never restores the source server counter or starts an old timer automatically. Keep current retains an existing slot; Use backup submits a guarded replacement. Stable restore action IDs make the same reviewed retry deterministic. Invalid current revisions fail with a readable error instead of an integer-conversion crash. Encrypted recovery/cache snapshots also retain the pending command chain.

Each repository owns these deployed migration copies, aligned with the inspected remote migration history:

- `20261006073641_durable_focus_session.sql`
- `20261006075121_focus_session_resume_access.sql`

The table has owner `USING`/`WITH CHECK` RLS, an indexed account key, explicit authenticated grants, no anonymous table/RPC access, and no client service-role credentials. The RPC uses `auth.uid()` and an empty search path, following [Supabase's function security contract](https://supabase.com/docs/guides/database/functions#security-definer-vs-invoker) and [RLS guidance](https://supabase.com/docs/guides/database/postgres/row-level-security).

## Focus session widget

The eleventh widget kind offers small and medium sizes. It follows the active workspace's current session, with per-instance standard/rose/lavender/mint appearance and **Hide task title**. The clock stays visible in privacy mode; the task name is removed from the view and marked privacy-sensitive otherwise. Task names are bounded to 160 characters/1000 UTF-8 bytes in the credential-free App Group projection. Full notes, authentication tokens and executable Focus mutations are not copied. A missing task has no retained title or fallback to another task.

Running timers use [Apple's bounded timer interval text](https://developer.apple.com/documentation/swiftui/text/init(timerinterval:pausetime:countsdown:showshours:)), while paused timers retain their remaining time and ended timers show time spent. A three-digit minute value uses a smaller font so 180:00 fits. Explicit finish and 24-hour freshness entries update labels and prevent old workspace data being presented as current; the clock derives from UTC timestamps rather than per-second timeline requests. [WidgetKit dynamic dates](https://developer.apple.com/documentation/widgetkit/displaying-dynamic-dates) supply the system clock behavior. Source renders cannot prove system refresh scheduling or closed-app delivery.

Idle, paused, ended, finished, unavailable/completed task, conflict and stale/old-publisher states have explicit copy. Pending sync has an accessibility-labelled cloud. Unreadable workspace caches require refresh. Conflict creation and successful resolution republish the current widget state; resolving a conflict cannot leave an old Review label behind.

A tap opens `taskfold://focus?account=…` through the native system URL handler. Both apps reject malformed/foreign-account links and capture the current workspace generation before presenting the newest session. Signed-out widgets open Taskfold's ordinary entry route. Start/pause/resume/end take place in the native app with its existing revision checks and replacement confirmation. The widget does not send timer commands or credentials to the backend. Cross-device changes reach the widget after its app receives and publishes them; no independent widget network sync or finish alert is claimed.

## Acceptance still required

The native timer, shared persistence contract and dedicated **Focus session widget** are implemented in both repositories. The existing **Focus** widget continues to suggest a next task. Remaining acceptance includes installed host configurations and multiple instances, finish notifications, actual paired/offline native device switching, reboot/physical/iPad/closed-app hosts, account revocation/reentry/restore walkthroughs and native Mac runtime. Each platform's validation record distinguishes the host evidence actually obtained. The Mac desktop remains locked; compilation does not prove Mac user behavior. This feature does not complete the full P0 objective.
