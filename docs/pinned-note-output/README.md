# Pinned-note PDF native acceptance — 28 October 2026

This checkpoint extends the reviewed-output safety work to the real pinned-note
reader. Each repository owns its fixture and native tests. Release behavior and
saved formats are unchanged; only stable reader/library accessibility identifiers
and reserved DEBUG fixture seeding were added to application sources.

## Accepted scope

Two selected cases pass each on iPhone 18 Pro and iPad Air 13-inch (M4) Simulator,
with zero failures/skips/reported XCTest runtime warnings. They cover:

- Real Browse → Pinned notes → long note → PDF review, dark largest mobile text,
  actual local Files Save/readback, repeat Save/Cancel and cleared stale success.
- Multiple actual PDF pages with first/eighth sections and final instructions,
  absence of the task CSV action, unchanged saved tables and cold return.
- A raw Unicode note edit while the actual Save picker is open: picker dismissal,
  unavailable export controls, no success/output, unchanged saved tables and cold
  return. This changes real in-memory Store state in the reserved fixture, not a
  mocked exporter callback. It does not establish genuine cross-device sync.

Six final mobile screenshots were inspected. Export titles, page/note count,
Save/Print controls and source-change recovery are readable. The library's large
introductory text scrolls normally; below-viewport content is not a clipping defect.
PDF renderer styling was unchanged; no new PDF raster or hardware-print audit is
claimed. Actual saved PDFs, final sources/binary hashes, strict summaries and
commands are retained in the iOS repo's corresponding evidence directory.

On Mac, the real signed isolated app was operated through CUA: toolbar → note
reader → PDF review → native local Save, followed by repeat Save/Cancel. The
actual two-page output passed independent PDFKit readback, and the cancelled
attempt cleared the previous success message. The screenshot in the conversation
was inspected; no persistent Mac screenshot is claimed. Its actual PDF, readback
script and manual scope receipt are retained in the Mac repo's evidence directory.

## Diagnostics and limits

The Mac XCTest runner twice timed out enabling automation before app launch.
Both selected cases compile; they are not accepted as executed Mac cases. Native
Mac source revocation, exact cold-return preservation and runtime-warning acceptance
remain open. macOS also refused direct private-container reads; no permission or
protection was changed to bypass that refusal.

The first mobile driver looked for Pinned notes in the Today menu. It now uses
Browse. At largest text it then waited for a lazy note row without scrolling its
library. A temporary bounded reserved-host callback trace recorded both tap and
presentation, and an actual screenshot showed the open library. This disproved
the tentative tap-target hypothesis. The attempted hit-area patch and temporary
trace were removed. The final driver scrolls the actual library and reader before
selecting visible controls; saved-file/source/preservation assertions remain intact.
Initial and rejected runs are diagnostics, not passing suites.

Real external file-provider delivery, authenticated account-picker/multi-window
races, other task/CSV largest-text flows, spoken output and hardware printing
remain separate requirements. All data was synthetic. No audio, privacy setting,
provider registration, hosted schema, rollout or release setting changed. The full
Px goal remains active and user deferrals remain in force.
