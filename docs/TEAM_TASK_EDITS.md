# Team task edits — disabled candidate, 24 October 2026

This stage supplies a guarded adapter for edits to existing team tasks. It does
not enable team editing in the app. The native project catalog still reports
`can_edit_tasks: false`; workspace selection, role refresh and the remaining task
commands must be accepted before exposing an editor.

## Server contract

`taskfold_edit_team_task(_body)` is an authenticated invoker entry point to a
private, narrowly guarded definer. The request freezes account session authority,
team, project, task generation, request UUID, baseline and desired fields. There
is no timestamp expiry for offline edits. Current live verified Auth/session,
current project editor/manager access, an active team and an unarchived project
are checked under locks. The separate `native_task_edits_enabled` switch defaults
off, and native reads and the team setup switch must also be enabled.

Supported fields are title, description, priority, due date/time, completion and
its time, deadline, duration, time zone and scheduled instant. Each field needs
a baseline; completion also requires the completion revision. The existing
three-way merge and generation/completion triggers remain in force. Dates and
times retain the existing normalization. Unsupported structural, assignment,
checklist, reminder-policy, comment and file operations require other adapters.
Create/delete/restore and recurrence generation are not supplied by this stage.

A private transaction scope admits only an UPDATE of the exact task generation
in its frozen project by its current actor. It does not admit another task,
project, section or comment. Direct REST and legacy public task writes keep the
previous closed team policy. The private merge implementation has no client or
service grant. Definer functions use an empty search path.

Durable receipts contain UUIDs, time and a keyed digest, without task plaintext.
A successful retry returns the current authorized task without reapplying the
old edit. A changed payload/actor cannot reuse a nonce. Current permissions are
checked before replay: a demoted member cannot retrieve the result. A deleted,
recreated or moved task requires review; a receipt cannot resurrect it. Receipts
are retained while the actor exists so a long-offline retry cannot become a new
mutation after history expires. Private tables have RLS and no client grants.

## Independently owned iOS and Mac clients

Optional `Mutation.teamTaskScope` is backward compatible with old persisted
queues. Old mutations remain unscoped; the sender never guesses team context
from a later project list. A scoped patch uses only the dedicated RPC with the
same persisted nonce on transport retry. The account, server and session
incarnation are checked, replies are bounded to 256 KB, redirects/cookies/cache
are disabled, and every response identity is verified before acknowledgement.
Raw server details are not shown. Denial keeps the local draft and has no legacy
personal-write fallback.

Undo/redo keeps the frozen workspace, recaptures only the same task incarnation,
and gets a new command identity for each committed action. Explicit conflict
review also gets a new nonce and cannot rebind an edit to another project or
recreated task. Unavailable-project recovery cannot discard a scoped team draft,
including when an earlier unscoped mutation in that project triggers recovery.
The app's commit boundary validates scoped actions before applying them locally.

## Verification and limits

Each repository independently ran 70 real PostgreSQL checks against its own
migration. These include editor/guest permissions, retained removed-author
content, private receipt/scope isolation, all capability boundaries, field
conflicts, completion cycles, replay after later work, personal patch regression,
and two overlapping transactions (permission revocation and task conflict while
waiting). Both owned containers were removed. Official advisors report no errors
or additional warnings; existing dependency-fixture init-plan warnings remain
recorded in `p2-team-task-edits-evidence.json`.

Each repository also ran 59 selected SwiftPM tests: 11 new team edit tests plus
48 project-read/automation/email regressions, with no failures or skips. Each
native contract test reads that repository's independently SQL-produced fixture.
These cover persistence, Undo, review, recovery, request nonce/context, failures,
late session responses and response bounds. Evidence hashes identify the exact
sources/resources. Store syntax and Xcode project lint are checked separately;
SwiftPM excludes Store, and these checks are not an app-runtime/build claim.

There was no hosted mutation/deployment, real user data change, native team UI
acceptance, notification delivery or Storage-provider test. Other task adapters,
role refresh/workspace cache rules, premium team/folder/admin/invitation flows
and backup/activity/widget acceptance remain required. Wider Px, Watch/Wear OS,
email configuration and every existing user deferral retain scope.
