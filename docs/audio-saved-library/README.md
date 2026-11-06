# Retained private recording inventory — 2026-10-28

This checkpoint adds storage APIs only. The normal audio feature gate remains
closed, and no account-library screen, playback/export action, task migration,
account purge, server operation or production task change is introduced.

## Behavior

`AudioCommentVault.savedLibrary()` reads all saved private recordings in the
already app/origin/account-separated vault, regardless of whether their original
task/project still exists. It does not need a fake current task or mutate the
original target, ID, revision, exact caption or clip bytes. A pure location helper
compares against targets admitted by the caller's live workspace: a project move
is distinct from unavailable/recreated/ambiguous task identity. These labels are
information, never task access or publication authority.

One vault lock covers inventory and pending-operation inspection. Saved primaries
owned by unfinished Save/discard operations are hidden; recovery-file,
pending-Save, publication and interrupted-file counts stay separate. Counts are
files/operations, not deduplicated recording totals. The inventory preserves
covered reviews and incomplete bytes without cleanup, promotion, Save or publish.
Malformed canonical data, unsafe filesystem entries and busy locks refuse the
snapshot instead of claiming a successful partial/empty library. Incomplete
staged bytes are counted without trying to interpret or repair them.

`savedLibraryRecording(expected)` rechecks an exact selection under that same
lock before returning bytes. It refuses stale/deleted/replaced selections,
foreign owners and newly pending primary Saves. A consumer must also bind/recheck
its live account, origin and workspace scope at the handoff, and fully decode the
native codec before playback. This API does not authorize task mutation or
remove any file. The actor exposes both reads away from the UI actor.

## Verification

Each repository independently passes 135 focused Core cases (zero failures),
including 12 new tests covering old-target retention, move/deletion/recreation,
ambiguous identities, exact raw-account isolation, stale revision/deletion,
pending journal and lost draft-commit acknowledgement, non-destructive covered
review inventory, separate publication/incomplete stages, corrupt canonical
publication refusal, symlink refusal, concurrent lock refusal, and actor selection
revalidation after an independent writer. Byte-for-byte directory snapshots
include the lock file and confirm preservation where applicable. Fixtures use
synthetic media and disposable directories; no microphone, permissions or real
user data are involved.

Both independent native test-product builds and strict deep app signatures pass.
These are development/Simulator build checks, not release-distribution acceptance.

`core-tests.log.gz` retains the exact run. `verification.json` binds the Core
sources/tests and native build/signature results. Existing unrelated compiler
warnings are retained, not represented as warning-free acceptance. No new native
UI run is warranted for this storage-only addition; prior native evidence belongs
to its original checkpoint. No real-media, Mac runtime or cloud/provider
acceptance is claimed.

## Still open

Account-library UI and its live-scope/handoff tests; export/import and portable
media backup; explicit removal/account lifecycle; moved/orphan playback recovery;
shared/private server delivery; genuine microphone/speaker and permissions;
broader native/cloud acceptance. The inventory is groundwork for those flows,
not evidence that these gates are complete.
