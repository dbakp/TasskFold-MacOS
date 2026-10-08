# Build artifact retention

On 8 October 2026 the user explicitly requested pruning artifacts no longer needed. Earlier verification had accumulated separate Xcode and SwiftPM build/cache directories without retiring superseded ones. This was the main storage growth; keeping new log/result identities did not require keeping every compiler and SDK cache.

The cleanup reclaimed about **75 GiB**, leaving about **77 GiB free** when measured. It removed obsolete generated contents from 195 verification directories and ten default SwiftPM cache trees. Both app repositories, all source copies, CLI logs, test-result bundles, captures and the current four native/four Core build roots remain. The 1,950 protected direct log/summary/receipt files were checked unchanged. Eight current app/widget binaries were checked present and hashed. No live build was stopped, installed Mac app was touched, or user data/system storage was removed.

`build-artifact-prune-2026-10-08.json` records the exact removed paths, measured capacity and retained current products. `du` can double-count APFS shared blocks; before/after free space is the recovery measurement. Old receipts still document completed checks, but superseded compiled-product/cache paths may now be absent by this authorized cleanup. Their pre-cleanup preservation statements remain historical.

## Policy for subsequent verification

- Keep one reusable native build location per platform/configuration and one reusable Core scratch location per platform/configuration. Each repository owns its inputs; no sibling build dependency is introduced.
- Reuse build caches only after the previous process reaches an actual terminal state. Preserve the failed source revision/manifest and diagnostic evidence before any correction or replacement.
- Give each command log and result bundle a unique name. Retain useful failure logs, native results, captures, source manifests and committed source revisions; these do not require retaining every old SDK/compiler cache or successful generated product.
- Retire superseded temporary compiler, SDK, index and intermediate/product directories after their checks have been recorded and the retained current build is verified. Keep the current usable products until replaced by a verified build.
- Check free space before a build cohort and run resource-heavy builds sequentially. If space is tight, first prune obsolete task-owned caches; do not delete user files or system/other-project storage.

The storage gate is resolved. The full P0 objective remains unfinished: isolated filter failed-save recovery and phone/tablet walks now pass; existing real paired-account, provider, physical/provisioned-widget and restricted Mac-runtime gates remain separate. Cleanup adds no runtime acceptance claim.

## Follow-up inventory on 8 October

A second inventory found 62 older native build roots whose remaining products did not satisfy the first pass’s stricter intermediate-directory classifier. Removing their 208 obsolete generated product/compiler/SDK cache directories recovered another **10.36 GiB**, leaving **84.64 GiB free**. The current four native build roots were excluded while the isolated iPad test was running. All 5,973 retained files under those old roots’ Logs/TestResults directories were hashed and checked unchanged. Source trees, Git, test results and captures remain. [Exact follow-up receipt](build-artifact-prune-followup-2026-10-08.json). Total measured recovery across cleanup passes is about **85 GiB**; subsequent verification has consumed some free space.
