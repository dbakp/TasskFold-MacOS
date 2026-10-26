# Harness correction

The first phone/tablet case incorrectly expected three initial rows and two
without checklists. The source query includes a dated heading as readable context:
the real contract is four rows, then three, while the productive task count is two.
A new Core scenario proves the same query/capture/export path, and the native
expectations were corrected with actual-label diagnostics. No source task was
removed or hidden to satisfy the test. Both final native cases passed.

The initial XCTest suites reported completed assertion failures, but their CLI
collectors did not finalize result bundles. Those already-failed owned collectors
were terminated (143) before rebuilding/retrying. Their text logs are retained in
the iOS evidence; they are not passing app acceptance. The earlier breadcrumb
follow-up fixes a real nested-path omission and is separately covered by Core.
