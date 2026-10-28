# Unknown prepared Save checkpoint — 2026-10-28

The implementation preserves the exact authorization across uncertain retries,
requires an exact stored-intent match for prepared state and clears inherited
durability before attempting a separate copy. No file format changed.

## Repeatable checks

Run `swift test --filter AudioComment`, then
`python3 Scripts/test_audio_comment_capture.py` and
`python3 Scripts/test_audio_claim_processes.py` with separate scratch/output paths.
Each repo passed **80 Core cases, 84 controller checks and the process probe**.
The controller probe uses a second real file descriptor holding the vault lock.
The optional default-nil beforeSaveState injection checkpoint is not a production
failure mode or an alternate storage implementation.

`controller-before.json` records six failures among 74 checks using the original
controller logic with the added default-nil lookup injection hook. The original
Core state comparison failed six assertions in one case (`core-before.log.gz`).
`copy-before.json` records the one failed durability check among 78 after the
first retry fix but before the copy fix. Frozen inputs are retained for each.
Final reports include source hashes and compiler diagnostics; existing warnings
have not been represented as fixed. `source-binding.json` binds the three tested
Core/controller/probe sources in this checkout.

## Native limits

Both final isolated native products compile and their signatures verify. Final
iPhone and iPad Simulator runs each pass four actual cases, with zero failures,
skips or reported runtime warnings. Three new cases cover prepared and committed
unknown retries and cold recovery at standard text size; the existing largest-text
discard/relaunch case also passes. No failed suite is accepted as a passing run.

The Mac CUA session observed the synthetic unknown prepared Save twice refusing
under the lock, the caption refusing editing, controlled process stop, one pending
Save after relaunch, one completed draft and exact caption/recording readback after
a second relaunch. `mac-cua-binding.json` in the Mac repo binds that binary and
source. It predates the Form accessibility identifier addition, DEBUG-only footer layout
correction and subsequent test driver edits. It is not exact-final-binary or normal-Quit acceptance.
No real microphone, permissions, playback sound, production tasks or server were
used. The isolated Mac process was closed afterward.

## Historical pre-journal failure — workspace-return follow-up

`open-prejournal-diagnostic.json` is a failing Mac-controller diagnostic, copied
here as an explicitly open contract-level finding, not another passing case.
The actual private lock first prevents automatic checkpointing; Save then fails
before its journal rename and its state lookup is locked too. After workspace
closure and releasing the lock, returning to the original owner still cannot
retry the retained review. There is no journal on disk. The retained writer's
Save freeze is not resolved. `open-prejournal-proof.swift` and its log preserve
the reproduction. It is outside the 84 passing checks and has not been accepted
as fixed independently on iOS.

The next implementation must resolve that exact attempt on original-owner return
without thawing a prepared Save, losing copy choices or writing across owners.
Orphan/corrupt-file recovery, background/Quit/removal/backup lifecycle, ordinary
integration and private server publication/access/custody also remain open.
The user deferred real dictation/audio tests; ordinary audio entry points stay gated.

### Native driver attempts

The initial phone run failed all four cases and iPad passed two of four.
The first viewport driver failed all four phone cases and three iPad cases.
The next center-gesture attempt passed the existing largest-text discard case on
both, but the newly added largest-text fixture footer/scroll targeting still
failed. After that failure, the remaining redundant run was interrupted; its
partial summaries are retained as failed, not accepted.
The final targeted driver scrolls inside the Form cell margin, accounts for the
test footer, explicitly resets normal content size, and keeps full-control
visibility assertions. New unknown-Save journeys target standard text size;
the existing discard/relaunch regression retains the largest text size. This
narrows native acceptance scope rather than claiming new large-text coverage.

The standard-text attempt passed all four selected iPad cases (strict verification,
zero failures/skips/reported runtime warnings). Phone passed the discard regression
but failed the new Save visibility assertion. Its remaining cases were interrupted
after the overlay cause was confirmed. The Form extended under the debug footer;
Save's bottom was covered. The fixture now gives the footer a separate VStack
layout region instead of applying an inset to the navigation container. This is
DEBUG-only test instrumentation. `ios-footer-build-binding.json` binds the preceding
partly accepted build; final layout-build evidence is recorded separately.

### Final accepted layout build

`phone-final-summary.json` and `ipad-final-summary.json` each report four passing
cases; the corresponding strict-verification receipts reject missing coverage,
skips, failures or reported runtime warnings. Native logs and source/app/test
binary bindings are retained with the final signatures. The source controller and
Core tested by the independent 80/84 checks did not change during driver fixes.
Representative final phone/iPad unknown-Save, restored-caption and largest-text
discard screenshots were visually inspected. The native recorders and players are
synthetic/silent throughout. The accepted layout-run raw results were subsequently pruned after the
workspace-return follow-up; persistent summaries/logs/captures and exact source
bindings remain here. Obsolete failed/interrupted output was also pruned. Test sessions and used Simulators were closed.


2026-10-28 follow-up: the workspace-switch reproduction is resolved by retaining
and explicitly finishing the exact pending Save, including separate-copy choice.
See [workspace-return evidence](../audio-comment-workspace-return/README.md).
Historical diagnostic files above remain unchanged. The full audio gate remains
open for lifecycle, integration, private publication and real-audio acceptance.
