# Recording-backup import — 28 October 2026

The independently owned apps now include a gated return path for the existing
`taskfold-recording-backup-v1` JSON export. Start from a currently admitted saved
personal-root/Inbox task, choose a recording file, review its literal caption and
duration, then explicitly Save a separate private draft. This is not a workspace
restore and does not resurrect the source task or transfer its identity.

Opening or cancelling the review does not write media to the private vault.
Confirmation requires a fresh audio editor, so an existing or unsaved recording
cannot become a replacement candidate. Reopen the task's audio drafts to import
another file. Confirmation passes through the existing recovery writer and Save
journal; unconfirmed saves remain in the ordinary retry/recovery flow.

The file reader coordinates security-scoped file access off the UI thread. It
rejects non-file URLs, directories, malformed/unsupported/inconsistent files and
oversized files; streaming stays bounded even if a file grows after metadata is
read. Cancellation reaches the file coordinator and read loop. Full native AAC
decoding precedes review and is rechecked before confirmation. Scope loss closes
the importer; late cancelled results cannot create a review. The destination is
bound to the original account, origin, workspace and exact task incarnation.

## Recorded verification

- Each repo independently passes 230 actual controller/codec/vault checks,
  including 19 new import checks, with zero compiler warnings. These use a real
  AAC file and private storage plus synthetic media drivers, without microphone,
  permission dialogs, speaker output or network calls.
- Both native apps build and pass strict deep development-signature checks.
  Existing unrelated project build warnings remain in the logs; this is not a
  warning-free whole-project claim. The unchanged Core contracts' 141-case
  acceptance remains at the prior export checkpoint; it was not rerun here.

## Limits

Ordinary audio entry points remain gated. Real microphone/speaker/TCC testing is
explicitly deferred by the user. Actual Mac picker/spoken acceptance, external
cloud providers, physical-device cases, bulk workspace/media backups,
account-removal custody, unfinished orphan recovery and private server delivery
remain open. Deferred rollout/signing work stays deferred.

The first phone test driver searched for a filename without its extension. The
native Files hierarchy exposed the full `.json` name; the selector was corrected.
That failed attempt is retained as diagnostic evidence and is not acceptance.

The next diagnostic attempt correctly found the file but refused to replace an
older fixture input with a newly generated AAC container. The fixture now
recognizes only its own exact synthetic format/caption/field set before resetting
that single input, before the source-preservation baseline is captured. It never
overwrites an unrecognized file. This attempt is also excluded from acceptance.

A third diagnostic attempt did not verify file selection after tapping its large
text label. The final driver uses the observed file-cell thumbnail, requires the
picker to dismiss, then scrolls the actual review form before checking its caption.
The introduction was shortened for accessibility text sizes. No viewport or
source-preservation assertion was weakened.


## Native acceptance and retained files

The final phone and iPad Simulator runs each pass one real native UI case, with
zero failures/skips/reported runtime warnings, at dark Accessibility XXXL. They
choose the actual local JSON file through Files, review the complete caption,
Cancel unchanged, choose it again, explicitly Save a separate recording, then
cold-launch and verify both saved drafts. Native assertions compare the original
private file, external input, decoded audio, caption, independent draft ID and
canonical task rows. All eight explicit final captures were visually inspected.

`phone-input.json` / `ipad-input.json` are the actual synthetic inputs;
`*-custody.json` records their hashes and the two independent saved drafts after
cold return. `*-summary.json`, `*-verification.txt`, compact logs and captures
record the native acceptance. `controller.json` records all 230 checks.
`source-binding.json`, build logs, signing receipts and artifact bindings bind the
source/build scope. `diagnostics/` contains only failed driver attempts, excluded
from acceptance. Cleanup receipts record pruned owned raw artifacts.

The iPad initially opened Recents instead of the app's local folder. Its final
driver adds navigation through the observed On My iPad sidebar control. The
passed phone driver is retained separately as `phone-driver.swift.gz` with its
binding; no product source changed between the final phone and iPad runs.
Development signing is not release/distribution acceptance.
