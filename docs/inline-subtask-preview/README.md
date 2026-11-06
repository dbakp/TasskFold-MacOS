# Readable preserved subtask previews

Reviewed 1 November 2026. Both repositories own their implementation independently.

## Result

A saved child with exact unknown metadata could retain a readable title on disk yet appear as an untitled subtask in the legacy inline editor. The Mac inspection reproduced that mismatch. The inline row now reads only its unambiguous title, completion and type fields. Preserved values and legacy text appear as readable text with “Review before editing”; the row never enables the full-object replacement writer. Completed and heading/unknown-type states use the same read-only projection.

The selected-field reader validates the full source syntax but decodes only requested ASCII fields. It never substitutes that display projection for the source. Original Unicode key spellings, exact numbers, unknown containers and nested values remain intact. Duplicate/escaped aliases of a known field still fail at decoding; unsupported title values ask for review rather than being coerced.

## Verification

Each repository independently passes 115 focused Core checks with no failures/skips. Five new cases cover exact metadata, completed and heading/future type display, field-selection boundaries, ambiguous/invalid titles and cold decoding. Earlier test compilation attempted to construct an invalid preserved value through a private initializer; the corrected test verifies rejection at the public decoding boundary without widening that initializer.

The native editor journey now checks the real title, a correctly named disabled completion control, and byte-for-byte unchanged source before changing the project. It then exercises assignment, Undo/Redo and cold return. Mac, iPhone and iPad each pass the full native journey without skips. Every observed title is readable, its correctly named completion control remains disabled, and previewing leaves the source bytes unchanged. The complete project/assignee Undo/Redo and cold-return flow also passes; each repository independently verifies all 15 exact snapshots. Cropped title screenshots, native logs/summaries and source/build hashes are retained in the three destination folders and verification.json. Both apps/runners build and pass strict signatures.

## Scope

This improves reading in the legacy inline editor; it does not authorize opaque full-object edits, complete storage migration, restore historical child recipients, prove speech/largest-text/all-library behavior or change normal-use gates. No database code changed or database suite was rerun for this display fix. The earlier assignment-guard database candidate remains undeployed. Genuine hosted/shared-account and broader migration/custody checks remain open.

The earlier Mac re-entry failure was a test issue: accessibility selection left the project popup open, and clearing task selection hides the inspector rather than showing a “No Task Selected” label. The native test now dismisses the menu explicitly and observes the actual hidden inspector before reopening. Project/generation/workspace and private-draft guards remain unchanged.
