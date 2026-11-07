# Read planned dates only when a query needs them

Each filter predicate previously projected every timed task into the viewer's calendar even for priority, completion, text, project, label or assignment conditions. TaskCache then projected again for every scope, including All, saved filters, Inbox and projects. These pure timezone/calendar calculations ran on a cold query's synchronous read path.

A predicate now computes its planned day on first use, at most once within that predicate. Today and Upcoming scopes still project the viewer's date; other scopes no longer compute an unused day. Date/deadline semantics, clock/date-preference admission, tri-state evaluation, target availability, hierarchy masks, cache keys/order/invalidation and saved data are unchanged. No long-lived date cache or new source/context admission is introduced.

Both owners independently measure the same 1,000 timed-task cold saved query on this Mac in Debug, with productive reading prepared outside the timed interval and a fresh query cache each repetition. The iOS owner improves from a three-run median 366.57 ms to 8.85 ms; Mac from 364.99 ms to 9.13 ms. Baseline/final ordered IDs match exactly, as do repeated cached reads; input rows remain unchanged. This is scoped query work, not optimized-app latency, physical iPhone FPS, rendering, drag or general navigation acceptance.

Each owner passes 210 focused checks with one intentional real-model skip (211 selected); the benchmark is explicit opt-in and has no timing threshold. New scope coverage preserves New York-to-Copenhagen rollover, Today/Upcoming versus non-date scopes, completion visibility, date/deadline combinations, target/text conditions and unchanged input. Existing filter, hierarchy, assignment, natural-date and planner cases remain in the final run.

Reproduce: TASKFOLD_TIMED_FILTER_BENCHMARK=1 bash Scripts/test_core.sh --filter 'FilterTests|SharingFilterTests|FilterTargetCatalogTests|FilterAssistanceTests|TaskKindTests|TaskAssignmentProvenanceTests|NaturalDateTests|PlannerTests'. The two named timed-projection cases also run against the prior source for the baseline. App builds and normal Mac delivery are recorded separately after compilation. The full Px goal, broader performance/native scope and existing deferrals remain open.

## Build and delivery scope

Current-source ad hoc signed arm64 iOS Simulator compilation passes; no native interaction or phone install is inferred. The Mac owner builds optimized signed 1.2.0 (36), verifies app/widget/share profiles and exact archive readback against retained Mac35, and installs after a fresh verified private safety copy. All nine cache files stay byte-identical before launch. Native Upcoming still has two tasks and reaches Synced 10.58. After the user approved the confirmed app-data prompt, the connection banner cleared and the original readonly postlaunch comparison completed successfully. The same app process remained running throughout verification. No task data or identifiers are published here.

The user's approval also closes the earlier Mac35 shared-storage gap: its native connection banner cleared before update. That is recorded separately, rather than treating the new36 permission wait as continued35 startup. Source flags and hosted services remain unchanged; phone installation stays deferred. Actual phone FPS, broad navigation/rendering and all remaining Px requirements remain open.

## Final Mac36 postapproval result

The user approved36's confirmed app-data prompt. Its native connection banner cleared in the same running app. Original readonly job38599 completed exit0 without restart: all tasks and pending changes are preserved across nine caches. Seven files are byte-exact; the others differ only in dates and cached _conversation_views. Comparison preserves Decimal precision and signed zero. The detailed report and cache/account identifiers stay in the private safety copy; only aggregate proof and its hash are retained here. This proves normal startup/storage/data preservation, not physical FPS or every widget action.
