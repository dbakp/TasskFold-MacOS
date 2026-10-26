# Reviewed CSV source mapping

26 October 2026. Both apps now offer **Map a CSV file…** in Templates and
**Map CSV columns** in explicit text intake. This creates a reusable project
workflow after a complete review and Add to templates. Opening, mapping or
cancelling creates no tasks or projects. A new run remains a separate action.

## Mapping contract

The first row names the columns. Users explicitly choose title, notes, row and
parent references, task/heading type, priority, estimate, labels, planned date,
deadline, time and time zone. There are no guessed type mappings or automatic
heading prefixes. Blank type cells mean ordinary tasks; custom Task and Heading
values are exact and case-sensitive. Heading definitions remain gated by the
existing local authoring capability. The normal app configuration stays unchanged.

A single imported project workflow keeps row order and the declared parent tree.
Source references are used only to resolve that tree, then replaced with file-local
references. Duplicate/missing references, cycles and depth beyond ten are refused.
Ordinary task checklists and headings retain their existing meaning in templates.
No account identity, completion status, attachment, assignment, discussion or
source history is imported. Unmapped columns are explicitly listed before review.
Source titles and notes are literal text, including apostrophes and formula-like
prefixes. Existing portable export supplies spreadsheet escaping afterward.

Dates require YYYY-MM-DD and become civil-day offsets from the reference date
chosen in the mapping screen. The next run chooses its own start. Priority is
1–4, estimates 1–10,080 minutes, and labels use semicolons with up to 100 distinct
names of 160 characters each. A mapped time or time zone needs a planned date, so it cannot
silently disappear when creating a run. Existing template validation checks clocks,
time zones, field types and final encoded size.

Input is bounded UTF-8 comma-separated CSV: optional BOM, quoted commas/newlines,
doubled quotes, at most 64 columns, 5,000 data rows and 2.1 MB. Every nonempty row
must match the header width. Empty records are ignored. Versioned Taskfold CSV
retains its strict separate import path. Invalid input is refused as a whole.
Other delimiter formats, source project/section catalogs, recurrence definitions,
assignments and completion-history migration are outside this mapping contract;
unmapped source columns are visible rather than silently interpreted.

## Native flow and safety

Both apps own the model and views independently. File access keeps the existing
bounded coordinated/security-scoped read; iOS retains its picker-session binding
and Mac retains its native file importer. Parsing and definition building run off
the main actor. Cancelled/stale reads cannot present a result. Workspace changes
invalidate old approval; text intake retains the explicit rebind flow. Mapping and
full contents review are distinct steps, with Back/Edit column mapping available.
The existing stable-request private-template Save/Undo path is reused.

## Verification

Each repository passes 87 selected Core checks without failures or skips, including
12 new source-mapping cases. Coverage includes heading gates/custom values,
forward parent references/order, literal source text, ignored identity/completion
columns, fresh runs, DST civil offsets, malformed data, duplicate/out-of-range
mappings, cycles/depth and the full 5,000-row/64-column bounds. An earlier broader
selection skipped four existing hosted integration cases because their disposable
fixtures were absent; those were not acceptance for this change.

Native results, source bindings, screenshots and cleanup are recorded in
`source-csv-mapping/`. Native Mac, spoken/largest-text, provider-backed file handoff,
real-device and genuine cloud/cross-device acceptance remain separate gates.
No hosted migration, provider registration, rollout or release setting changed.

The final current-source text-mapping scenario passed on both iPhone and iPad,
including complete-review Cancel, mapping revision, Save and exact cold return.
Native Mac startup awaits Xcode UI automation approval; its signed harness is
prepared. Final screenshots/results and retained harness failures are separate.
