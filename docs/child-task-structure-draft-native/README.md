# Native organizer drafts

Both independently owned apps now checkpoint unfinished Add/Move organizer edits into the encrypted draft journal. Done awaits a successful checkpoint and keeps the window open on failure. The organizer and recovery list expose full-title Resume/Discard controls. Empty untouched composers do not consume draft capacity. Draft loading belongs to the scoped screen model; a separate draft-file read failure does not hide saved actions. Scope departure clears the displayed recovery data.

Saved placement is not silently rebased. Title-only edits retain its original binding; choosing/reviewing the current destination is explicit. Recreated targets cannot be followed. Before handoff, the exact action and request identity are frozen in the draft file. A lost local reply recovers the same saved action rather than inventing another body/ID. Sending remains separate. Cleanup failure retains the original handoff for recovery.

## Accepted scope and phases

Each repository passes **126 hierarchy Core cases**: 29 command, 13 read and 84 recovery. Eleven new integration/session cases extend the preceding 13 draft-storage cases. They cover edits during a held write, save failure/retry, scope departure, empty sessions, immutable cold promotion, lost post-write acknowledgment, explicit placement review, body collision, strict/legacy decoding, draft discovery/discard and independent draft-read failure. Complete app/test products build and their development signatures verify; normalized built-source hashes match.

| Native phase | Passed / selected | Scope |
| --- | --- | --- |
| Initial phone | 2 / 4 | Draft rows did not load. Existing insert/send and move/send passed. |
| Section-loading attempt, interrupted | 0 / 2 attempted | First draft case still failed; run stopped after that failure. Two other selected cases never started. |
| Screen-model loading | 3 / 4 | Discard/Cancel and existing insert/move Send pass. Cold resume and action Save progressed, but the test queried an offscreen lazy row without revealing it. |
| Scrolling correction | 0 / 1 | Original three-minute allowance expired at the final diagnostics read. No allowance was raised. |
| Phone, compact diagnostics | 1 / 1 | Exact Add-draft cold return/edit, unsent-action text, cold queue readback and zero automatic task writes/requests; 136.941 s. |
| iPad, compact diagnostics | 2 / 2 | Same cold handoff (138.313 s), plus Discard Cancel/confirmation (56.705 s). |
| Phone, stacked actions | 1 / 1 | Final large-text layout, explicit Resume with exact title, Done, Cancel and private-only discard; 68.590 s. |
| iPad, stacked actions | 1 / 1 | Same final action/layout flow; 71.905 s. |

The compact test-only diagnostic label reads the same actual journal/peer counters; it removes long scrolling through unrelated fixture controls. Assertions, app workflow and the **180-second default / 240-second maximum** remain. The final layout stacks actions at accessibility text sizes. Native checks verify at least 44-point heights, no overlap and a single-line Discard label; [phone](phone-actions.png) and [iPad](ipad-actions.png) captures were visually inspected. Scrolled action captures are not whole-screen title-layout audits; cold editor/value captures are retained separately.

All failed/interrupted/timeout phases remain in compressed logs, official summaries and source snapshots. These recorded phases are **not a single-binary sweep of every hierarchy journey**. Native cold handoff passed before the final action-only layout adjustment; the final layout round separately activated Resume and checked the unchanged draft plus discard boundaries. No new Mac runtime or spoken acceptance is claimed. Move-composer cold resume/current target-label review, broader account/window/background/failure/concurrent and genuine Keychain/Store acceptance, independent-record migration, older-data adoption and the rest of Px remain open. Normal gates and hosted schema are unchanged. No new simulator was created; owned devices were shut down after testing.

Obsolete result bundles were pruned only after concise evidence and selected captures were retained: 477.9 MiB of allocated files in `cleanup.json`. Current passing bundles/products were reused and retained.
