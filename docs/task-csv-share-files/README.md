# CSV Share to local Files and largest-text review — 28 October 2026

The existing Share CSV feature now has completed local handoff acceptance on iPhone and iPad Simulator, rather than only opening/cancelling the share sheet. No production behavior needed changing. The iOS repository adds a native regression that uses the normal Print or export → CSV review → Share CSV → Save to Files journey, verifies the delivered file, reads every displayed field at dark Accessibility XXXL, and checks unchanged saved tables and exported bytes after a cold relaunch. The Mac repository records this mobile scope; Mac Share acceptance remains open.

Both final results contain one actual passing test and pass the strict result verifier with no reported runtime warnings. Current app/widgets/share/UI-runner build and real-team Simulator signature verification pass. Relevant app/output/test sources match their retained host inputs. No Core logic changed, so no new Core-suite pass is claimed in this checkpoint.

## File and display evidence

Both delivered CSVs are byte-identical, 1,089 bytes, with the complete 19-column header and four file rows: two productive tasks, one included checklist detail and one context heading. Independent Python CSV parsing verifies the format marker, unique file-local references, forward heading reference and nested checklist parent, known literal titles/notes, understood types and no UUIDs in this synthetic fixture. This is readable task output, not restoration of assignment authority or completion history.

The native test brings each of 23 text fields separately inside the actual Form viewport below the CSV navigation bar. It records their rectangles and checks the full controls/text before continuing. All 20 final screenshots were inspected: included options/count, native local destination, and each row's title/final field on both devices. Text wraps without an application clipping defect in this fixture. Neighbour fields naturally scroll beneath the header; the test does not demand an entire tall row fit at once. Native Files can abbreviate its own folder/filename text at XXXL; the actual delivered filename and bytes are verified independently.

The destination is this reserved synthetic app's Documents folder. Files hides empty app folders, so the test seeds a 46-byte marker, confirms the local provider plus the folder title/toolbar and visible marker before Save, and refuses unknown existing test-file content. No cloud provider is selected. The marker and CSV are removed after retaining readback evidence; saved tasks remain intact.

## Retained attempts and driver corrections

Earlier attempts are not final acceptance. One expected a navigation-bar title where Files exposes a custom toolbar. A later phone run completed delivery before its row-container query failed; the identifiers are on the static text elements. The tablet's empty Documents folder was initially hidden. A cached phone browsing-root identifier then retained its parent title despite the correct folder toolbar/marker. Final confirmation uses all observed local signals rather than trusting that stale title alone.

The preceding tablet functional case passed, but its whole-window screenshot bounds could accept a partially visible row in the smaller sheet. The final test instead checks the actual sheet/nav viewport field by field. A test-only geometry stringification API failed compilation and was replaced with numeric rectangles. Two failed collectors were stopped with SIGINT then SIGTERM only after their actual testcase failures were recorded; their logs and available summaries remain failed/interrupted scopes. Final runs disable only verbose failure sysdiagnose collection, preserving normal testcase failures, activities, attachments and strict warning verification. Unexecuted intermediate builds are not native passes.

## Limits

This closes this four-row, default-content, dark-largest-text **local mobile Share-to-Files** scope. Mac sharing, external/cloud providers, physical devices, account-picker/multi-window races, spoken accessibility, larger/different exports and other output variants remain open. Previous Save/revocation and Core contract results remain separate evidence. No release/rollout/provider/reminder configuration, real task data or microphone permission changed. Full rank-3/Px completion is not claimed.

`verification.json`, source/binary hashes, final logs/summaries, exported CSVs, field geometry and screenshots bind the accepted scope. `cleanup.json` records owned artifact pruning after evidence retention.

Run `python3 verify_export.py` in this evidence directory to independently recheck the retained CSVs and sheet-bound records. The native test applies the additional navigation-bar inset.
