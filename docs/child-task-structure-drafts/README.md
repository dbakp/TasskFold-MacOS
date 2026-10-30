# Organizer draft storage

This records the earlier storage-only stage. The [native follow-up](../child-task-structure-draft-native/README.md) connects its screens and records the current verification limits.

This stage adds durable private storage for unfinished Add/Move organizer content in each independently owned app. It is a storage foundation: the organizer screen is not yet connected to it, so closing that screen can still lose unsaved composer text. No new everyday-use feature is claimed.

## Behavior

Drafts keep the exact title, original task/project/generation, moved-node incarnation, destination incarnation, structural revision, position and stable future request ID. Blank titles and currently unplaceable positions can be saved privately. They cannot become a command until a current hierarchy read passes the original identity, revision, destination and command checks. Reopening does not silently rebase a position or follow a recreated node. A future live editor must also supply its current scope/access lease; durable draft identity is not authorization.

Each bounded account/server file uses the existing authenticated encryption and private file permissions. A separate draft journal never enters the task-action queue or sends a request. Revision tokens prevent stale windows from overwriting or discarding newer content. Exact retries are idempotent; stale updates cannot recreate a removed entry. Unreadable work is preserved, and capacity refuses new drafts rather than evicting unsent work. The Store owns a dedicated account/server path and includes keyless cleanup in confirmed account deletion and isolated-fixture reset.

## Verification

Each repository passes 115 selected hierarchy Core checks: 29 command, 13 read and 73 recovery cases. Thirteen new composer checks cover exact unfinished text/cold journal reopening, no queued actions, blank/unplaceable content, stable request identity, stale hierarchy/root/project/incarnations, competing windows, retry, failed/cancelled writes, encrypted scope/permissions/corruption, removal fencing/keyless cleanup, capacity, strict wire parsing, simultaneous independent drafts and unreadable storage. These are storage/controller checks, not native UI acceptance or a multi-process stress proof. The Store factory/deletion wiring still needs its later native integration checks.

The first Mac phase failed one new test setup: moving to an empty destination retained the source position 1. Explicitly choosing position 0 makes that valid review pass; the original rejection was correct. The 71-case intermediate pass and final expanded 115-case passes are recorded separately. No failed phase is counted as a pass.

Both full isolated app/test products build and pass development-signature verification. The new source is present in each app compiler input, and normalized built-source hashes match. No new native composer runtime or real Store deletion journey is claimed.

## Remaining

Connect checkpoints and explicit Resume/Discard to the organizer and recovery screens; preserve drafts across dismissal, background/relaunch and scope changes; bind safe promotion to the existing saved-action identity without duplicate actions after uncertain local writes. Then verify native phone/iPad/Mac, current access and concurrent-window behavior. Full independent-record migration, older-data adoption and broader team/audio/lifecycle work remain open. Normal feature flags and hosted schema are unchanged.
