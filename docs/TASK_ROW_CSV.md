# Reviewed task-row CSV export

26 October 2026. Task lists now offer **Print or export**, retaining PDF/print and
adding **Export CSV…**. A separate CSV review shows the exact row count, all rows,
status/context and planning details, with explicit notes/checklist choices and
native Save CSV / Share CSV actions. Pinned notes keep PDF/print only.

## Data contract

The new UTF-8 format uses the complete 19-column header in TaskRowCSVFormat and
`taskfold-task-rows-v1` on every row. It contains file-local row and parent
references, group and parent path, known task/heading/unavailable type, literal
title/notes, completion status, readable project, priority, stored planned date,
time/time zone/scheduled instant, deadline, estimate, label names and assignee name.
It deliberately excludes backend/account/task-generation identifiers, attachments,
discussion, mutation queues and completion-history ledgers. It is readable task
output, not a backup or history-restoration format. Stored planning values remain
as authored, including the exact instant alongside any wall-time fields.

Every displayed group gets its own rows; overlapping query groups may repeat a
task. Headings and included checklist details count as rows, not productive work.
A dated heading plus two ordinary descendants and one nested checklist detail
therefore exports four rows; excluding checklists exports three while the task
count remains two. Unknown future kinds are explicitly unavailable, not ordinary.
Malformed completion/numeric/text fields and unresolved project/label/collaborator
metadata refuse CSV as a whole rather than inventing values. Existing readable
PDF rendering remains available independently.

Parent references are scoped to file rows, including repeated legacy child keys
and forward references to visible headings. A filtered child keeps its readable
parent path without inventing nonmatching ancestor rows. Recursive checklist
paths retain the ancestors of projected subtasks as well as their immediate title.
Read-only capture includes accessible archived-project metadata and task roots,
so archived work can be exported without restoring its project. Editing safeguards
are unchanged. A Core regression verifies archived capture and unchanged inputs;
the native scenario uses active work. The source snapshot remains immutable. Label-catalog lookup is indexed once per
capture rather than rescanned for each source reference.

CSV has quoted commas/newlines/doubled quotes and CRLF records. Formula-like text
and literal apostrophes use the existing reversible spreadsheet escape. Label
names use JSON-array cells so semicolons, backslashes and literal spaces survive.
The explicit CSV mapper recognizes only this complete supported header/marker,
reverses its text escape and decodes a labels cell only when that column is mapped
to Labels. Generic CSV keeps its own literal text and semicolon label syntax.
Tampered/unknown task-row markers are refused. Mapping into a reusable workflow
still needs the separate review/Save and existing heading capability; completion
history and assignment authority are never inferred from the file.

Output is bounded to 5,000 rows and 2.1 MB, with no truncation. Options can remove
notes/checklist rows before those output bounds. Generation runs off the main actor
and checks cancellation. The existing immutable print-request workspace/source
checks are reused. CSV controls accept only the result matching current options;
share representation rechecks source, workspace and captured options immediately
before data release. Source changes discard pending view/export state. Once the
user has handed bytes to a provider, external copies are outside app control.

## Verification and limits

Each owned repo passes 64 focused Core cases, including 14 new CSV cases and PDF/
workflow regressions. Tests cover source privacy, real fields and status, scoped
references, filtered context, heading row/work counts, full projected breadcrumbs,
spreadsheet escapes, exact labels, fresh reviewed workflow conversion, refusal
and all row/byte bounds. Current iOS arm64 app/share/widget/UI-runner builds and
strict/deep Simulator signature checks pass. An independent Mac Debug app build
passes without signing; native Mac acceptance still needs Xcode UI automation.

One current-source scenario passes on each iPhone/iPad Simulator: open the normal
print/export entry, review four rows, exclude notes/checklists, observe three rows,
open/cancel Share, open/cancel native Save, and verify exact task-table preservation
and cold return. Both final screenshots were inspected. No share destination,
cloud provider or print job was invoked. These checks cover native cancellation,
not completed provider delivery, saved-file output or native source/account races.
Those, Mac runtime, spoken/largest-text and real-device/cross-device checks remain
open. Normal heading authoring, hosted configuration, release and rollout gates
remain unchanged. See task-row-csv/ for bindings, results and retained failures.

### Native Save/readback follow-up — 26 October

The scoped native Mac runtime and actual local saved-file checks described above
now pass; iPhone/iPad actual Save/readback also pass. Mac options/cancellation,
byte-identical full CSVs and exact saved-table/cold preservation are verified.
See NATIVE_TASK_OUTPUT.md for exact results, remaining keyboard/visual limits and
source/account/provider/spoken gates; this does not close the broader rank.


### Reviewed output safety checkpoint (2026-10-27)

PDF/CSV Save and CSV Share now check the exact source, selected options, workspace
incarnation and presentation at byte release. Old Save callbacks cannot settle a
new Save. UTF-8 source changes invalidate the task cache and the captured review.
Actual native local Save/readback, cancellation, source/incarnation revocation and
cold-return preservation pass on Mac/iPhone/iPad (4/5/5 selected cases). External
providers, authenticated account-picker/multi-window and spoken/largest-text gates
remain open. Already-released bytes cannot be recalled. See
[verification and limits](task-output-release/README.md).

## 2026-10-28 — CSV Share to local Files at largest text

- [x] Complete the real Share CSV → local Files Save/readback/cold-return journey
  on iPhone and iPad Simulator at dark Accessibility XXXL.
- [x] Independently parse the byte-identical 19-column/four-row files and verify
  file-local references, literal notes/titles and absence of fixture UUIDs.
- [x] Check 23 displayed fields per device inside the actual sheet viewport;
  inspect all 20 final screenshots. Two strict native cases pass.
- [ ] Mac Share, cloud/provider, physical-device, spoken, larger-output and
  account/window acceptance remain open. Production output behavior is unchanged.

Exact scope, driver failures and readback: [CSV Share to Files](task-csv-share-files/README.md).
