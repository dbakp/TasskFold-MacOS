# Full task-note rows without interface-thread conversion

6 November 2026 · rank 3, responsiveness and accessible note reading.

At accessibility text sizes, a task row previously converted the whole note to
readable text synchronously from its view body. Both owning clients now prepare
full note text on a serial actor, then detect its web links in cancellable
background work. The row keeps its bounded compact preview and a neutral
“Preparing full note…” indicator while this runs. The complete readable note
replaces it when ready; there is no new truncation of the full reading.

Every result belongs to the exact UTF-8 source, task, workspace incarnation,
session, access epoch and read revision. A changed request or disappeared row
cannot publish the result. Store checks its current boundary before and after
preparation. Cache invalidation cancels queued/running jobs and rejects late
results; Foundation parsing already underway may finish before cancellation is
observed. A same-context invalidation retries only while the row remains current.
Rows release their prepared reading on disappearance. The shared cache remains
bounded to 128 readings and 8 MiB of source/result UTF-8 content, with no disk
persistence. Empty notes release the previous full-text entry.

Compact notes retain the existing formatter. Full readings retain the exact
existing plain-text and link-destination behavior, including oversized and
unsupported-markup fallbacks. This does not alter saved note bytes, task fields,
completion, children, history, rollout gates or hosted contracts.

## Validation scope

`verification.json` distinguishes each owner’s focused Core/build evidence from
actually observed native journeys. The iOS-owned fixture renders the production
TaskRow using synthetic data and keeps an all-table saved-state assertion. Its
first attempt passed size switching, live refresh and hide/return, then found
normal legacy view-preference migration during cold startup. The fixture now
performs that existing migration before taking its baseline; the all-table
assertion is unchanged. That initial failed run is not counted as acceptance.

Mac/iPhone/iPad interaction is accepted only where a corresponding current-source
report explicitly passes. This is not a physical FPS, universal long-note layout,
VoiceOver speech, shared/cloud/account/window or real-device performance claim.
Actual text layout and link-title rendering still run on their normal UI paths.
The wider responsiveness checkpoint remains unfinished. Installed apps and frozen
daily-use archives are unchanged.

## Reproduce

Each owning repository independently runs:

```sh
bash Scripts/test_core.sh --filter 'TaskNotePreviewReadTests|NoteMarkupTests|PreparedNoteMarkupTests'
```

The iOS owner additionally has `Scripts/test_full_note_rows_native.py`, accepting
a successful current-source signed build receipt and the existing reserved phone
or tablet Simulator. It verifies prepared Swift sources, the exact owning UI test,
strict signatures and unchanged products before accepting the saved UI proof.
It restores its previous device state and does not install to physical devices.


## Accepted current phone/tablet journeys

Each owner passes 33 focused Core cases, including eight new background-reading
cases. The current signed iPhone and iPad tests both pass the real TaskRow flow:
full tail text and formatting, compact/full size switching, live source refresh,
hide/return at a read boundary, preservation of every other task field, and exact
all-table equality after a cold launch. Both used devices return to their prior
state. These are iOS-owned synthetic Store/UI checks, not Mac interaction or
physical-device FPS/speech acceptance. The source-bound reports are `iphone.json`
and `ipad.json`. No curated bar is promoted to broadly complete.
