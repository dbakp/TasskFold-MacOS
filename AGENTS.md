# Working on Taskfold for macOS

- After implementing requested changes, run appropriate checks, commit the changes, and push them to this repository. The user explicitly wants all completed changes pushed, including follow-up fixes.
- This repository owns its Mac code, resources, tests and release scripts. Do not add build dependencies on the iOS repository. Preserve unrelated work in other checkouts; implement and test relevant data-contract fixes in each app repository independently.
- Keep the implementation status and verification notes in `docs/PREMIUM_MAC_PLAN.md` current while working through the polish milestones.
- Use isolated debug fixtures for UI tests; do not modify real task data for testing.

- Before heavy local builds, Simulator runs or Docker fixtures, run `python3 Scripts/check_test_storage.py --path /tmp` and require its default 20 GiB free-space floor. Reuse current test hosts/products, run resource-heavy platforms sequentially, and prune approved obsolete outputs after retaining concise evidence. Never reset Docker volumes or erase real app data as cleanup.

## Maintain the progress dashboard

- The user wants a small, continuously maintained HTML progress artifact. After each meaningful Px milestone, changed blocker or user deferral, review the current evidence and update `docs/px-progress.json`. Keep its review date accurate.
- Run `python3 Scripts/render_px_progress.py --refresh-sources`, then `python3 Scripts/render_px_progress.py --check`. Commit the snapshot and both generated HTML files with the corresponding work. Each repo owns its own renderer/data; never introduce a sibling-repo build dependency.
- Bars count curated checkpoints, not effort, time or release readiness. Distinguish verified scope, built-but-unaccepted work, implementation still needed and explicit deferrals. Do not count repeated historical checklist entries or test totals as product completion. Keep known gaps and normal-use feature gates visible.
- When showing progress in the conversation, refresh the inline fragment using `--preview-output` with the current task's durable visualization path. Updating the artifact is part of ongoing work, not a reason to start duplicate scheduled jobs.
