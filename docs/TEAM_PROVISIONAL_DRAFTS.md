# Saved provisional team drafts

Implemented 24 October 2026. Rank 6 remains in progress. Both repos own the code,
resources, migration and verification independently. Team editing remains disabled;
no hosted deployment or native runtime/visual/accessibility acceptance is claimed.

## Supported recovery path

A recorded completion may adopt another shared occurrence while this device has
edited its unused provisional next task. The review can now offer **Keep edits as
draft** for direct scoped patches/deletion and comment drafts on that exact unused
generation. It saves a full Recovery copy and a separate encrypted draft before
requesting a durable generation-retirement proof. Only then can it remove those
queued intents, acknowledge the recorded source/current shared occurrence and
resume unrelated sync. No public task is created, changed or deleted by parking.

The archive preserves the original typed completion, the full last local task,
every selected edit and comment intent, and whether local deletion was intended.
New work during a wait, mismatched authority/proof, unknown comment formats or a
persistence failure keeps the appropriate queue intact. A failed server request
can leave an accessible saved copy while its original queue still waits safely.
Unexplained root changes and replacement generations are not silently discarded.

This does not yet park mixed batches, compound completion/history groups, related
root edits, arbitrary pinned-note dependencies, or edited tasks whose original
completion was never recorded. Those paths stay queued for explicit cohort
reconciliation. A still-live own generation is shared work and cannot be retired.

## Durable identity proof

`taskfold_retire_team_provisional` uses the original actor/HMAC-bound recorded
completion to attest the prospective ID/generation. Live session, team, native-read
configuration and project read access are checked before the nonce mutex. Under
the task identity mutex it rechecks that the proposed generation is not live,
then records UUID-only custody and a deleted generation tombstone. Creation cannot
later reuse that identity, so delayed task/comment callbacks cannot gain a target.
Read-only members may retire their own unused identity without editing shared work.

The generation fence survives actor removal and team deletion under existing
UUID-only team custody. A private `team_provisional_retirements` marker distinguishes
an unused identity from a real task deletion. Canonical creation and Undo/Redo
history ignore purely provisional markers while still rejecting the exact retired
generation. Fresh legitimate occurrences remain possible; actual deletion history
retains its previous protection. The guarded completion function changes only this
real-history test, and all prior authority/baseline/transaction checks remain.

The response includes a strict recorded review and the current authorized row at
the prospective ID, including a replacement generation when appropriate. Native
parsing binds every scope/nonce/identity. The endpoint has authenticated-only grants,
empty search paths, bounded input/output and no client access to private markers.
Native transport avoids cookies/cache, refuses redirects and caps the proof at 2 MB.

## Device-private draft shelf

Backups & restore → **Saved team drafts** opens the encrypted shelf for the original
signed-in account/backend. AES-GCM binds ciphertext to both account and backend.
Files contain no plaintext title index. Scope changes dismiss/clear the view.
Account-removal gating prevents delayed saves, and account vault removal erases its
nested drafts; ordinary Recovery rotation cannot evict them.

Drafts have no automatic expiry. Capacity is 20 files, 16 MB per draft and 64 MB in
total; overflow fails before queue removal instead of evicting older work. Identical
retries deduplicate. The shelf exposes saved task state, planning, priority and
retained file/reminder counts, with bounded text previews. Copy/share uses final
saved text; superseded private text is retained behind a separate earlier-text
control. Original intents never replay automatically. Deletion of a saved copy is
explicitly confirmed and does not change shared tasks.

## Verification and remaining scope

Each repo independently passes 375 disposable database checks: 56 retirement,
131 completion, 67 review, 61 cancellation and 60 rebase regressions against the
new migration. Tests cover live-identity races under real locks, interruption
rollback, exact retries, late patches/recreation, legacy adoption and a fresh valid
canonical generation after retirement, real-deletion history, role/session/config
changes and actor/team cleanup. Advisors show no new warnings/errors against the
fixture baseline. No real user data or hosted state changes.

Each app passes 351 selected Swift tests (13 new draft/retirement cases; includes
44 backup tests) and unsigned Debug app/extension builds. Native tests cover strict
proof binding, direct edited/deleted drafts, comment intents, stale snapshots,
cohort refusal, encrypted account/backend isolation, tampering/oversize rejection,
deduplication, no expiry/eviction, Recovery rotation and account-vault cleanup,
final-only default sharing, and bounded account-bound transport. Owned containers,
temporary builds and temporary Mac registration are removed.

Remaining rank-6 work includes the other cohort/draft paths listed above, explicit
reapplication of full saved details, current-role workspace/cache refresh/privacy,
remaining collaboration adapters, premium organization UI and consolidated native
acceptance before enablement. Wider Px scope and the user's release/provider/
hardware deferrals remain unchanged.
