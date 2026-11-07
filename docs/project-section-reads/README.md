# Prepare native project sections once per read

Both native project lists previously scanned the complete current task list for every section. iOS also reread the filtered list and sorted the section catalog in each placement-key/metadata lookup. Mac reread regularTasks for every section, including its overdue detection. Each grouping pass now captures one immutable task/section reading, sorts the current project's catalog once and partitions task rows once. iOS list/board metadata and print groups use the same section IDs and existing placement keys. Mac keeps list-only overdue exclusion separate from board content and partitions the full board task input once.

ProjectSectionTaskRead retains no workspace, permission or editing authority. Callers still obtain current Store-filtered rows on every pass. It preserves source order and duplicates, empty sections, headings/child references and opaque values; unknown section references are not silently moved. Existing per-section priority/manual ordering, identity, collapse keys, capture and mutation paths remain unchanged. No persistent cache or invalidation scheme is added.

The explicit Core measurement compares the actual new reader with the previous repeated-filter grouping algorithm for 4,000 synthetic tasks/80 sections. Each grouped record is compared exactly. The reported same-host Debug preparation time excludes Store reads, ordering, screen rendering and user interaction; it is not physical FPS or whole-navigation latency. Native interaction/build outcomes are recorded separately. The preceding independently merged all-work/archive-filtered cache optimization is included in the current source.

Reproduce Core checks: TASKFOLD_SECTION_BENCHMARK=1 bash Scripts/test_core.sh --filter 'ProjectSectionTaskReadTests|TaskWorkloadCacheTests|TaskNavigationCountsTests|OrganizationOrderTests|HeadingProjectProgressTests|TaskKindTests|TaskQuery'. New cases compare the old grouping oracle, exact output/source order, duplicate IDs/catalog rows, empty/missing/foreign sections, headings/child references/completed rows, high-precision opaque fields, priority/manual arrangement, source/section edits and retained-snapshot immutability. The unrelated earlier workload benchmark is intentionally skipped.

Broader rendering/drag, native Mac behavior, physical FPS, shared/cloud/account/window/accessibility scope and remaining Px are not inferred from Core timing. Phone installation remains deferred; no hosted service or normal feature gate is changed.

## Focused Core result

iOS passes89 checks (90selected); Mac88 (89selected). Each intentionally skips the unrequested prior workload benchmark. Current source section-preparation medians are73.57→1.07ms (iOS owner) and72.18→1.07ms (Mac). Exact per-group records match the prior algorithm, including the separate source/identity cases. These are same-Mac Debug measurements, not rendering or physical-device FPS.

## Bounded cache follow-up

The first Simulator attempt stopped before tests with a missing Foundation .scan referenced by stale Xcode metadata after the preceding module trim. Only generated XCBuildData was retired; the same existing host/cache/products were reused. The cleanup tool now retires stale dependency plans with module inputs and budgets the entire selected cache, including protected products/evidence, rather than only candidate scratch. It reports an untrimmable protected remainder without deleting it. Each owner passes13 real temporary-file cleanup cases, including dry-run/healthy/live-build preservation and symlink refusal.

## iPhone native result

Three actual Simulator cases pass: collapse/expand and completion retaining empty section headers, contextual capture, drag-to-section creation, and board completion/position plus assignee capture. Two accepted cases were retained from v4; only its remaining pre-board menu-locator failure was repaired/rerun in v5 (one selected/pass, zero skip). Both finalized result summaries have no runtime warnings. The reserved host initially excluded the requested test class, then the older tests assumed projects above the expanded Browse tools and a menu identifier retained by iOS; those precondition failures are explicit in the accompanying evidence, not counted as acceptance. Actual touched app files match the owner exactly; the signed app compiles. This is interaction/identity scope, not physical-device FPS, Mac behavior or broad rendering acceptance.

## Normal Mac37 delivery

Current owning source builds optimized Release37 with app/widget/share signatures, cached profiles and exact ZIP payload verified. Frozen36 rollback and its same nonempty designated requirement are verified. No source or normal gate changes occurred during build; no distribution acceptance is inferred. CUA reports the Mac locked, so the app has not been quit, the fresh pre-install safety copy has not been claimed, and37 is not installed. Normal36 remains running unchanged. One manual unlock request is pending; routine update authorization already exists. Phone installation stays deferred.
