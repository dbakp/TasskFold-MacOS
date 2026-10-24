# Current-access discussion screens

Open conversations, Mentions, composers and their refresh/member-list callbacks
now follow the same live access boundary as workspace presentation. Account
identity alone does not authorize a late response. A changed boundary, changed
project/membership catalog, or unreadable cache changes a local read revision;
responses captured under an older revision are discarded before committing.
Task/project/incarnation checks remain in place. Ordinary task text changes do
not invalidate the read revision.

The visible comment/mention projection is pruned before an encrypted Recovery
write can finish, without mutating the original snapshot or authored outbox.
Counters and pagination cursors carry the stable server boundary token, so a
count fetched before an access change cannot appear under the new boundary.
A matching stamp can survive relaunch. This is a consistency marker, not an Auth
credential. Legacy services use the existing empty marker until a boundary is
available.

An open composer keeps its authored text when a task becomes read-only or
unavailable. Send rechecks the current task, incarnation, project and write gate.
The latest shared-version section resolves only currently visible cache rows,
never the retained baseline; names and mentions use current accessible members.
Save draft remains available for private authored text in the same workspace.
Account changes still dismiss the composer and invalidate its callbacks. Shared
thread content disappears when its task is no longer accessible; open removal
confirmations also withdraw when reading or editing becomes unavailable.

Team discussion writes remain disabled with the unfinished native organization
adapter, including when the user is a task creator. Legacy/personal collaboration
retains its existing write/archive rules. Blocked existing outbox requests retain
their identity and content; the sender skips them without immediate retry loops.
A response already accepted by the server remains subject to the server's
idempotency and current-role rules; this stage does not claim new hosted delivery
acceptance.

Verification is in each repo's p2-discussion-access-evidence.json. Core checks use
real SQL boundary fixtures for projection, historical custody and native write
gates. The native fixture holds an old page reply, transitions a composer through
read-only and revoked access, then saves and relaunches its private draft. It uses
only the independently named Simulator app and synthetic data. No live Supabase
changes, real tasks or notification permissions are involved.

This stage implements the discussion-specific safeguards; verified platform
acceptance is scoped in the evidence above. Full rank 6 still needs
ordinary task-editor/inspector invalidation and unsent edit recovery, other draft
cohorts, remaining collaboration/organization adapters and premium team UI. Mac
runtime/VoiceOver and broader native acceptance are tracked separately; existing
provider/hardware/distribution deferrals remain intact.
