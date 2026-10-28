# Private saved-recording library — 2026-10-28

This checkpoint connects the retained-recording inventory to a read-only library
in both app repositories. The entry is in Backups & restore, under the existing
closed audio feature gate. Normal app Info files still omit that flag. The exact
isolated DEBUG fixture exposes the candidate for testing; production task data,
backend/schema contracts and sibling-repository dependencies are unchanged.

## User flow

The library shows saved private drafts across their original tasks/projects. A
user can open the entire written caption and play/stop a recording without
retargeting it, recreating a task, editing metadata, repairing files or publishing.
On iOS the library uses a large, page-sized sheet with an inline title; task/status labels wrap and plain rows keep their text readable. A moved task is labelled explicitly. A missing, inaccessible, recreated or
ambiguous task is labelled unavailable while its previously saved private draft
remains reachable by its owner. A current task name is shown only after actual
Store/editor admission with its original generation, not just a matching UUID.

The screen states that these device/account-private recordings are excluded from
workspace backups. Pending Save, recovery, publication and incomplete files are
kept separately and only receive a passive preservation notice here. This screen
cannot finish those operations. Unsafe or damaged canonical storage refuses a
snapshot instead of reporting an empty or partial successful library.

## Scope, bytes and lifecycle

The library binds to the exact raw account, server origin and workspace
incarnation with no fabricated task target. Storage uses the existing independent
app/server/account namespace. Selection reads the exact saved revision under the
vault lock, fully decodes its bounded AAC bytes off the UI actor, then rechecks
the exact source after decode. Native duration measurement may differ from an
older container estimate; original stored metadata/bytes remain unchanged.
Playback rechecks the saved revision and pending-Save status again before handing
bytes to the existing device adapter. The adapter shares the app's exclusive
media lease. No microphone or Speech Recognition permission is needed for the
library itself.

Late decode/playback callbacks cannot install a preview after cancellation,
backgrounding, Close or account/server/incarnation change. Inactivity stops
playback and clears the selected media; return requires a fresh selection and
source check. The shared background-preservation hook suspends this read-only
screen rather than permanently closing a still-current scope. Leaving scope
closes it and clears its rows/caption/media without deleting files.

## Verification scope

Each repo independently runs 191 actual controller/codec/vault checks with zero
compiler warnings, including 21 new library checks. These cover exact scope and
raw-account identity; unbound refusal; real full decode; full raw caption and
original target retention; playback/Stop; late callback revocation; server switch;
stale revision; Save begun between selection and Play; source edit during a
suspended decoder; cancellation; account-away-and-back/incarnation change;
backgrounding; shared inactivity and actual preservation hooks; foreground
revalidation; and original disk-byte preservation. Media output is synthetic and
silent. This is not genuine speaker/microphone/TCC acceptance.

`verification.json`, `controller.json`, `native-build.log.gz`, signature logs and
the build driver bind final source and native executable bytes. Existing unrelated
native compiler warnings remain recorded. Prior 135-case Core evidence still
belongs to the preceding unchanged-vault checkpoint, not a new Core run here.
Native Simulator results and captures are retained alongside this document.
The native journey enters the actual library through an isolated fixture button;
it does not separately accept activation of the Backups & restore row on each
platform. Fixture reset now restores only its three known synthetic records,
checking owner/task generation before replacing existing fixture tasks. A
separate reset-isolation case checks preservation of another synthetic owner's
files. Cold-return launches preserve moved/deleted task state. Initial native
failures and diagnostic corrections remain explicitly recorded in
`initial-native/`, `driver-timing/` and `fixture-reset/`; they are not accepted runs.

## Final native results

Two actual cases pass on each device (four total), with no failures, skips or
reported runtime warnings. They run at dark Accessibility XXXL. The recording
journey saves an Inbox draft through the real task editor, reviews and silently
plays/stops it, backgrounds/returns, moves its synthetic task, deletes it, then
cold-launches and reviews/plays again without recreating the task. Exact original
media-file bytes and task-table preservation are asserted between each read-only
stage; move/removal states are checked on disk. The companion reset case verifies
that another synthetic account's opaque file remains byte-identical. All eight
final stage captures were inspected. Phone captures show different scroll
positions; the unchanged strict viewport assertions separately check the entire
caption and each control, not all content simultaneously in one image.

## Remaining work

The library is a gated candidate. Export/import and portable-media backup,
account removal/purge custody, broader cloud/native runtime, orphan recovery of
unfinished reviews/journals, shared/private server delivery and genuine media
permissions/interruption acceptance remain open. Mac native interaction and
spoken accessibility acceptance are separate from its successful build/signature
and controller checks. No release-distribution or feature-complete audio/Px claim
is made. The user's microphone/speaker permission test remains deferred.
