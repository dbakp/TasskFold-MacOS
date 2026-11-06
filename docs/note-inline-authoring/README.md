# Complete inline note authoring

Write mode now exposes Strikethrough alongside the existing native formatting tools. It uses the reader's existing `~~text~~` syntax, preserves selected Unicode text and surrounding source bytes, selects an editable placeholder at an empty caret, and toggles an existing selection back to plain text. Preview uses the existing safe attributed reader. The canonical note remains ordinary text; no schema, cloud/provider, completion or permission contract changes.

Every formatting result now passes the existing 512,000-byte UTF-8 note bound before the editor accepts it. Previously bold, italic, code and link could grow a source already at the limit into a result the reader could no longer format. The baseline regression reproduces four failed assertions in the prior iOS owner. The common final guard also covers escaped links and multiline code-fence expansion; removing markers can still shrink a full note. Refusal leaves the original editor text intact rather than truncating it.

## Scope still open

This is a note-authoring increment, not complete notes/Px, all-keyboard/speech, shared-account/window or physical performance acceptance. Mac native interaction remains separate from its build result. The installed Mac30 predates this source and still awaits its system app-data approval; that process is kept intact. Phone installation remains deferred. No real task data, hosted service, normal rollout gate or system setting changes.

## Verification

Each owner passes 52 focused formatting/markup/preview/widget checks, including seven new inline cases. They cover selected decomposed Unicode/emoji and exact toggle bytes, selected placeholders, the reader's actual strikethrough attribute, safe-link/plain fallback, every inline style at the exact bound and one byte above it, shrinking full notes, multiline fences and escaped-link expansion. The retained baseline is the actual prior iOS-owner run, not an assertion that both old owners were executed.

Current-source signed phone and tablet journeys exercise the ordinary focused note editor and reader. Actual button taps insert, remove and restore the selected markup. Preview does not save. Explicit Save changes only the note description while completion, children, opaque task fields, pins and unrelated tables remain exact; actual Store Undo/Redo and cold table readback pass. Final phone controls/preview and tablet preview screenshots were inspected. The independent Mac app builds and passes strict signature verification; Mac control interaction/speech and physical performance are unclaimed.

Initial native attempts stopped on an inaccurate SwiftUI/XCTest `isHittable` flag, despite a visible in-bounds control. A scroll attempt and removing an unnecessary text tap did not resolve that metadata refusal. The final case uses the normal tap API and verifies the actual resulting text after every tap; it does not substitute a model call or relax the saved-data assertions. Those actual tap journeys pass on both devices. Core reproduction: `bash Scripts/test_core.sh --filter 'NoteInlineFormattingTests|NoteFormattingTests|NoteParagraphTests|NoteListFormattingTests|NoteMarkupTests|FormattedNoteWidgetTests'`. Native case: `WorkflowSourceSelectionUITests.testPinnedNoteStrikethroughPreviewSaveUndoAndColdReturn`.


Delivery update, 6 November: the accumulated source is installed in [Mac 1.2.0 (31)](../mac31-daily-update/README.md). The normal main window, sync and preserved tasks/pending queues are verified after a private safety copy and exact archive/signature checks. Wider feature acceptance remains scoped; phone installation remains deferred.
