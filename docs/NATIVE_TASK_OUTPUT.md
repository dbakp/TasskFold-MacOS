# Native task output follow-up

26 October 2026. Both independently owned apps clear the preceding CSV saved
message when starting a new Save attempt, matching the PDF flow. Cancelling a
new picker therefore does not leave an old success message on the review.
The Mac list menu now says **Print or Export…** so CSV is discoverable. A scene-
bound File menu command advertises the same review with Command-P; it reads the
current list and is unavailable while its print review is already open. The
existing immutable source/workspace checks still guard PDF and CSV output.

## Acceptance scope

Only reserved signed debug copies and synthetic local workspaces are used.
Native exported CSV is parsed independently with Python's CSV reader: the full
19-column header, four displayed rows, one heading, complete notes, forward root
reference and nested checklist reference are retained. Mac's explicit exclusions
produce three rows with empty Notes. Backend identities, account identifiers and
assignment authority are absent. The full CSV from Mac, iPhone and iPad is byte-
identical. These files are task output, not backups or completion-history restore.

The actual saved Mac A4 PDF has two pages. PDFKit verifies both page dimensions,
readable first/eighth sections and the final instruction. Both rendered pages
were visually inspected: headers, footers, multilingual text, emoji, lists and
pagination are readable, without clipped content. This is an actual native Save
output rather than only a Core renderer fixture.

Native scenarios also verify cancellation and exact saved-table preservation,
including after cold return. The final result mapping is recorded in
`native-task-output/acceptance.json`; failed attempts remain separate evidence.
The iPad's initial successful save had its status below the lazy sheet viewport;
the final test scrolls to it. Initial Mac queries used the wrong accessibility
roles, and a later attempt selected a Touch Bar Cancel duplicate. Test-driver
cleanup was moved outside the sandboxed runner because it can read an exported
file but cannot delete a file written by the host's granted save-panel access.

A system local-network permission prompt interrupted initial Mac keyboard/input
attempts and covered part of their screenshots. It was not accepted by automation;
local output/cancellation needs no network or printer delivery. Thus those
attempts alone do not prove a broken shortcut or a completed keyboard gate. The
File command and toolbar path are verified only to the scope of their retained
native results. Genuine printing to hardware, external-provider/cloud handoff,
source/account races, spoken/largest-text and wider multi-window/keyboard checks
remain separate gates. No schema, hosted data, feature rollout, real task or
user-deferred release/provider/reminder/upgrade setting changed.

All test handles were terminal before cleanup. Removed 1.79 GB of owned scratch
builds/results, verified synthetic exported files and both isolated Simulator
app/runner installations after retaining the evidence. No Taskfold app process
remains; repository build caches were preserved. Exact bytes and paths are in
`native-task-output/cleanup.json`. The phone run predates only the test's iPad
scrolling correction; app code is unchanged, and final tablet/Mac source bindings
are retained.


### Reviewed output safety checkpoint (2026-10-27)

PDF/CSV Save and CSV Share now check the exact source, selected options, workspace
incarnation and presentation at byte release. Old Save callbacks cannot settle a
new Save. UTF-8 source changes invalidate the task cache and the captured review.
Actual native local Save/readback, cancellation, source/incarnation revocation and
cold-return preservation pass on Mac/iPhone/iPad (4/5/5 selected cases). External
providers, authenticated account-picker/multi-window and spoken/largest-text gates
remain open. Already-released bytes cannot be recalled. See
[verification and limits](task-output-release/README.md).
