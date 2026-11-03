# Project catalog reads — 3 November 2026

Both apps now reuse one derived project catalog while the readable source,
access epoch, account/workspace generation, session and original server match.
It provides ordered projects, the active hierarchy, archived hierarchy and
inherited archive IDs. Task workload and active-task reads use the same archive
projection. Every getter still reads the current presentation before a cache
hit, retaining observation and access filtering. Source/mask/readability changes
clear the value; a changed workspace/session/origin cannot reuse another value.
Permission and mutation admission readers are unchanged.

The outline walk uses an explicit stack while preserving sibling order,
conservative cycle handling, missing-ancestor archive flags, duplicate precedence
and the display depth cap. Historical chains deeper than the authoring limit no
longer consume a recursive call stack. The sorted duplicate archive precedence
used by the original Store is retained; direct `outline` callers keep their
original input semantics. Catalog values remain read-only copies.

## Verification

Each independently owned selected Core run reports 174 cases: **170 passed,
four existing opt-in integration cases skipped, zero failures**. Five new cases
cover cache reuse and all context boundaries, copy isolation, 16 mixed legacy
ordering/archive graphs, sorted conflicting duplicate precedence, a 12,000-node
legacy chain and the opt-in timing diagnostic. Existing project/workflow and
workspace tests remain included. An initial new assertion assumed the first
ordered record was the tree root; it is correctly the child in the flat order.
The assertions now select that record by ID. Those two initial assertion failures
are not final passes.

The iOS Core diagnostic performs 20 equivalent catalog-reading passes over
4,000 projects (1,000 roots and three children each). The actual pre-change
pipeline took 0.7836 seconds; the current cached pipeline took 0.0192 seconds.
Both consume the same 168,000 result items. The Mac-owned current diagnostic
took 0.0185 seconds; no separate Mac before measurement is claimed. These are
single Debug diagnostics, not release, hardware, FPS or end-to-end latency
measurements.

The real iPhone Simulator app passes one production-list journey: seed 4,000
projects and 240 tasks; measure the actual Store reads; verify observed rename,
reparent/archive inheritance, archived task exclusion, unreadable hiding and
readable return; open the production TaskScreen and scroll to different rows.
All saved task/project fields and queued work remain identical. The actual Store
20-pass diagnostic took about 0.0237 seconds. There is no native before timing.
The app is terminated and its previous Simulator boot state restored. This is
an isolated local workspace with synthetic data, not shared/hosted Auth testing.
`iphone-after.json` contains the actual test summary and source/product hashes.

Both full apps and test runners build and pass strict development-signature
verification. The screenshot shows the actual production list after scrolling;
its layout, actions and styling are unchanged by this optimization.

## Still open

This accepts one project-catalog workload and bounded iPhone browsing. It does
not close the broader performance checkpoint. Template-library summaries still validate documents while rendering rows, and
parent-choice generation still validates candidates independently. Those paths
need profiling and implementation improvements where costly. Other project
distributions, larger workflows, Mac/iPad runtime, window/account changes, largest
text, audible speech and real cloud contexts still need their own evidence. Existing deletion,
rollout, remote-reminder, signing/provider and other user deferrals are intact.
No hosted data, schema, release configuration or feature gate changed.

## Reproduce

```
bash Scripts/test_core.sh --jobs 2 --filter 'ProjectWorkflowsTests|ProjectWorkflowIntegrationTests|TeamWorkspaceTests'
```

Set `TASKFOLD_PROJECT_CATALOG_REPORT` to a task-owned `/tmp/taskfold-*.json` path
for the opt-in diagnostic. The iOS repository additionally owns
`Scripts/test_project_catalog_native.py`, which reuses the reserved prebuilt
host/products. Neither app depends on its sibling repository. Storage checks
and sequential heavy runs follow each repository's AGENTS instructions.
