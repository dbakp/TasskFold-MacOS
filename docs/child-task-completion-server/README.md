# Independent child completion and certified Undo: disabled server candidate

The dedicated `taskfold_complete_child_task` command implements Complete, Reopen and Undo for one independently addressed child. The canonical migration is `20261029211038_child_task_completion_commands.sql`, generated with the Supabase CLI after direct SQL execution and advisor checks. Both repositories own a copy with the same backend migration identity. No hosted deployment, direct task policy or ordinary app flag changed.

## Resulting behavior

The request carries root/project/generation, child key/incarnation/revision and an explicit completion baseline; it cannot carry a parent tree, title, notes, scheduling or arbitrary field changes. Complete stamps the actual server event time. Reopen clears that child’s completion time. Neither action completes descendants, changes the parent’s completion version or generates a root recurrence successor.

Undo names the original actor-owned receipt. The server restores its original flags and completion time, including absent legacy flags, while advancing the current completion token in the same epoch. An adopted legacy token remains after Undo so a completion cycle cannot disappear from subsequent concurrency checks. Unrelated current fields, sparse/absent/null child containers, descendants, siblings and opaque extensions are preserved from the locked current tree.

Disjoint field edits may survive a pending completion or Undo. The actual completion cohort and per-field revisions detect a later cycle even if the child ends in its earlier visible state. Replaced/deleted/recreated children, changed root generation/project, heading/future types, unsupported completion metadata and exhausted counters require review. Each original receipt can be undone once; Undo of an Undo needs a new explicitly reviewed ordinary action instead.

Exact retries return the stored original revision and completion metadata and produce no second write or history event. Changed bodies cannot reuse the UUID. Receipts and nonce reservations do not expire into fresh mutation authority. New requests have an actor-scoped 2,000/day budget; known retries bypass the new-request count after current permission checks.

## Admission and atomicity

- The public wrapper is a security invoker. Private mutation authority is confined to a helper with an empty search path, bounded lock timeout, live confirmed account/session checks and explicit personal ownership/project or current team editor admission. It also requires unarchived projects and the existing native team gates.
- The new `completions_enabled` flag defaults to false and additionally requires existing child reads and edits. A later [client stage](../child-task-completion-client/README.md) provides proofs, journaling and Backend transport; no ordinary Store/UI route is connected.
- Existing Auth recipient, team/config/project and root lock order is retained. Live admission is checked again after waits and before proof is committed. The tests expire a real session while the command waits on the root lock.
- Team changes use a private transaction-scoped write authorization after admission; existing root guard, assignment, heading, child projection and actual node-history triggers still execute. The update is restricted to the server-built subtree. It does not route through the checklist adapter that normalizes legacy containers and restamps historical times.
- Post-write own-fields/incarnation/tree verification, history and receipt persistence are atomic. A mismatch, caller-RLS refusal or later error rolls back all changes. Private scope rows are removed on success and disappear on rollback.
- Completion UUIDs are refused by field preparation/receipt/closure writes. Field/closure identities are refused by completion. Team commands also reserve the shared team request namespace under the same lock with a distinct `child_completion` operation, which cannot certify a generic checklist Undo.
- Receipt tables have RLS and no direct anonymous/authenticated/service-role access. Stored before/after metadata excludes task titles, notes, files and other authored content. There are no new public data tables or broad task grants.

The node-history revision helper now uses the valid checklist epoch/version token when present, while retaining legacy `completion_version` fallback. Actual completed/reopened events therefore record the same version as the command receipt; malformed tokens cause explicit unsupported history coverage rather than a fictitious revision.

## Verification and limits

See `verification.json`, per-repository database reports and compressed logs for exact checks, source hashes and cleanup. Each owned fixture loads the real root/child history and custody migrations, the project/team/root guards, and the child projection and field/closure commands. The iOS harness uses its own older migration identities where they differ from macOS.

Coverage includes actual personal/team transitions and historical times, disjoint edits, cycles, exact/lost-response retries, one-use Undo, sparse legacy restoration, access loss, archived projects, account/session rejection, real lock waits, nonce collisions with ordinary team/field/closure commands, post-write and caller-RLS rollback, receipt budgets, privileges/RLS and advisor deltas. Existing child-field regression runs load this migration as an overlay.

The local full Supabase stack is not running; `supabase migration list --local` could not connect. Isolated fixture execution does not establish local/hosted migration-history parity. No release, upgrade or hosted deployment claim is made.

## Still required for the complete feature

- Strict typed proof validation, durable journal and dedicated transport are implemented in the later [client stage](../child-task-completion-client/README.md); Store/native integration remains open.
- Terminal completion outcome/closure and explicit replacement of ambiguous attempts, plus Store account departure/removal wiring and genuine lifecycle acceptance.
- Store integration and premium native completion feedback/review/Undo controls.
- Current app builds, real native/lifecycle/concurrency/accessibility acceptance, legacy/adoption/structural adapters and authoritative independent-child migration before ordinary exposure.
- Previously agreed deferrals and the recorded combined-run iPhone interaction finding remain unchanged.

The later [terminal recovery stage](../child-task-completion-resolution/README.md) now supplies permanent closure/applied decisions and durable fresh replacement guards. Earlier verification below describes this stage’s own scope; Store/native exposure and genuine acceptance remain open.
