# Portable recording backup export — 2026-10-28

This checkpoint adds explicit per-recording backup export to the gated private
recording library in each app. Normal Info files still omit the audio exposure
flag. It does not implement recording import, bulk workspace/media backup,
account purge, server publication, or release acceptance.

## Format and copy behavior

The user chooses Export recording backup, then a destination through the native
Save picker. The JSON file contains exactly `format`, `caption`, `descriptor`
and `audio_base64`. Its version is `taskfold-recording-backup-v1`. It retains the
exact caption UTF-8, original clip bytes and original descriptor, including older
container-measured durations. It excludes structural account, task/generation,
project, server, publication, path and source-filename links. User-written caption
content is preserved literally. The filename suggestion is fixed, not derived
from a task title or account. This is a **plain, unencrypted portable copy**;
privacy/protection of the chosen destination is separate from the private vault.

The codec bounds input before decoding, admits only the exact schema/version,
validates caption/base64/descriptor/container integrity, and refuses malformed,
unknown or oversized input without changing private files. The file budget is
base64 expansion of an 8 MB clip plus 40 KB for caption escaping and metadata.
Encoding does not escape base64 slashes. A maximum-size padded valid container
and a maximally escaped 4 KB caption reproduce a failure with the earlier encoder
and pass with the correction. Decoder admission is not native codec proof:
playback/import must still fully decode AAC.

## Source and provider permission

A library selection already has full native AAC decode proof. Export preparation
rechecks its exact saved revision before and after encoding away from the UI
actor. The provider permit freezes only that caption/audio copy and its original
private storage. At actual byte release it rechecks the saved source under the
vault lock, then rechecks live permission after the await. A changed/deleted or
pending-Save-owned source, account/server/incarnation change, manual refresh,
new selection/export, Close or cancelled presentation revokes pending requests.
Provider retries return identical frozen data. Cancellation clears the permit's
references; it cannot recall bytes already legitimately handed to the OS.

An explicitly initiated Save may finish while the native picker takes focus or
the app briefly backgrounds. Playback/selection still clear on inactivity, while
this separate account-bound Save permission stays valid through picker focus and
a foreground refresh. Fresh selection and ordinary manual refresh revoke it.
Callbacks belong to an immutable item ID; an older callback cannot settle a newer
export. Success/cancellation feedback is separate from controller refresh state
and clears on a fresh recording selection, avoiding a misleading saved indicator
on later selections. No export action saves/retargets a task, changes vault media,
finishes a journal, or publishes remotely.

## Verification

Both independent repos run 141 focused Core cases (six new portable-file cases)
and 211 actual controller/codec/vault checks (20 new export checks). The controller
proof uses synthetic silent media drivers and actual private storage. It covers
unselected refusal, exact output, retry, cancellation, new item/selection/manual
refresh revocation, picker/foreground survival, stale/pending source refusal,
server/scope departure, Close, cancellation during preparation, permission change
after storage await and original private-file preservation. Existing unrelated
Core compiler warnings are retained; the controller compiler has no warnings.

Native build/signature and Simulator results are bound in `verification.json`.
The native journey enters the real task editor/library through the exact isolated
fixture. It saves a synthetic clip, removes only its synthetic task, cancels the real Save picker, checks source
preservation, saves to an observed local app Documents folder, independently reads
the delivered JSON/audio/caption/descriptor and actual Save receipt, then cold
launches and verifies both copies, unchanged task-table bytes and that the removed
task is not recreated. It also checks
that a fresh selection clears old Save feedback. Phone cancellation uses the
standard sheet-dismissal gesture when the compact picker lacks a direct Cancel
button; iPad uses the observed Cancel control. No cloud destination is selected.

`Scripts/test_audio_recording_backup_file.py` admits an actual delivered file with
this repo's Core and fully decodes its AAC without playback. Running it separately
from both repositories against the delivered device files verifies the portable
contract independently. This is not an import-UI or genuine media acceptance test.
Initial phone driver failures and the maximum-size red test are recorded explicitly
in the diagnostic folders and are not counted as final acceptance.

## Final results

One actual native case passes on each Simulator (two total), with zero failures,
skips or reported runtime warnings. These final cases remove the synthetic task
before exporting and preserve its removal through cold return. All ten final
captures were inspected; phone captures show different scroll positions. Exact
whole-caption/control visibility and cleared feedback at the detail footer are
asserted separately. Both actual delivered files then pass both independent Core
and full native AAC decoders (four combinations), with zero compiler warnings;
file/audio/caption hashes agree. The CLI probes are Mac executables, not native
mobile import UI. Native builds and strict development signatures pass for both
apps; ordinary audio feature flags remain absent. No Mac Save UI was launched.

## Still open

Import/review into a chosen current task, bulk workspace/media backup, account
removal custody, orphan unfinished-review/journal recovery, actual Mac Save-picker
interaction, cloud/physical-device/provider and spoken accessibility acceptance,
genuine microphone/speaker/TCC/interruption tests, and shared/private server media
delivery. The user's genuine audio test stays deferred. App Store signing and
other previously tabled rollout work remain tabled. This advances recording
backup custody without claiming audio comments or the overall Px goal complete.
