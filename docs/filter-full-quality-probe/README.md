# Complete on-device filter quality probe

The opt-in filter test now records each of its five requests, even after a parse failure. Failed proposals retain the actual generated text and error in the synthetic observation; later semantic checks still run. A failed request or wrong match prevents the accepted marker. These logs are produced only for the fixed synthetic test goals, never by the production engine for user descriptions.

The driver now supports --engine filter or --engine steps so unrelated actual inference need not repeat. It requires five filter observations (the old driver still expected three), unique engine/goal observations, the requested suite's accepted marker, unchanged source, a successful test exit, matching expected task IDs and valid step shape when requested. Format/parse success is not semantic acceptance. Ordinary runs still skip real inference unless explicitly requested.

## Current production-engine result: not accepted

The actual Mac-hosted engine returns all five observations in about 9.5–10.3 seconds each on this warm run. Three requests match the nine-row future-date oracle correctly. “Find unfinished priority 3 tasks planned for today” returns prose and is refused by the ordinary parser. “Find open work in project Work, including its subprojects” returns project:Work AND open: valid syntax but only three of four expected matches, omitting the child project. Both fail explicitly, the test exits 1 and realGenerationAccepted stays false. This closes the previous fifth-request observation gap; it does not complete filter quality or native assistance acceptance.

One bounded syntax-repair attempt in the same model session, a fresh-session repair and introductory-verb normalization were each tested and rejected. The repair attempts still failed the fourth request; the full runs also expose wrong project scope. None is adopted. Production FilterAssistanceEngine, FilterParser and the native helper view are byte-identical to the merged baseline. No automatic second inference, permissive parser path, guessed join, changed project scope or unsupported alias is shipped. The ordinary preview and explicit Use then Save remain unchanged.

No task/filter write, private task/catalog input, cloud inference fallback, model setting, account permission, service, normal gate or installed-app update occurred. Normal Mac35 remains running with shared-storage/readback pending; phone installation remains deferred. Broader models/languages/native flows/quality and the full Px goal remain open. Do not repeat these unchanged prompt experiments; the recorded counterexamples govern the next design.

Reproduce the exact current-engine negative result: python3 Scripts/test_ondevice_quality.py --run-model --engine filter --output /tmp/taskfold-NEW-filter-quality.json. The matching ordinary suite is FilterTests|SharingFilterTests|FilterTargetCatalogTests|FilterAssistanceTests|TaskBreakdownTests. Results and source identities are separate JSON evidence. Apple's [guided generation documentation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation) describes output-shape constraints; the genuine semantic counterexamples above are our own local evidence.


Subsequent 7 November update: the original [Mac35 postlaunch data check](../mac35-postlaunch-readback/README.md) completed. Tasks and pending changes are preserved across all eight cache files; shared-storage readiness still requires native inspection.
