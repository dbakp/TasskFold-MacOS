# Working on Taskfold for macOS

- After implementing requested changes, run appropriate checks, commit the changes, and push them to this repository. The user explicitly wants all completed changes pushed, including follow-up fixes.
- This repository owns its Mac code, resources, tests and release scripts. Do not add build dependencies on the iOS repository. Preserve unrelated work in other checkouts; implement and test relevant data-contract fixes in each app repository independently.
- Keep the implementation status and verification notes in `docs/PREMIUM_MAC_PLAN.md` current while working through the polish milestones.
- Use isolated debug fixtures for UI tests; do not modify real task data for testing.

- Before heavy local builds, Simulator runs or Docker fixtures, run `python3 Scripts/check_test_storage.py --path /tmp` and require its default 20 GiB free-space floor. Reuse current test hosts/products, run resource-heavy platforms sequentially, and prune approved obsolete outputs after retaining concise evidence. Never reset Docker volumes or erase real app data as cleanup.

## Complete GitHub delivery

- The user requires completed changes to be committed, pushed, and merged every time. Create or update a pull request against the repository’s default branch, wait for required checks, merge without bypassing branch protection, and verify the merged branch contains the completed commit. Pushing a feature branch alone is not completion.
- Keep each app independently owned. Merging source does not authorize enabling deferred rollout gates, publishing a release, changing hosted services, or restarting an installed app with unsaved work.

## Maintain the progress dashboard

- The user wants a small, continuously maintained HTML progress artifact. After each meaningful Px milestone, changed blocker or user deferral, review the current evidence and update `docs/px-progress.json`. Keep its review date accurate.
- Run `python3 Scripts/render_px_progress.py --refresh-sources`, then `python3 Scripts/render_px_progress.py --check`. Commit the snapshot and both generated HTML files with the corresponding work. Each repo owns its own renderer/data; never introduce a sibling-repo build dependency.
- Bars count curated checkpoints, not effort, time or release readiness. Distinguish verified scope, built-but-unaccepted work, implementation still needed and explicit deferrals. Do not count repeated historical checklist entries or test totals as product completion. Keep known gaps and normal-use feature gates visible.
- When showing progress in the conversation, refresh the inline fragment using `--preview-output` with the current task's durable visualization path. Updating the artifact is part of ongoing work, not a reason to start duplicate scheduled jobs.

## End every run with storage cleanup

- Before finishing **every run**, check free space and clean completed Taskfold-generated outputs. Record before/after free bytes and what was removed; never leave cleanup as a future promise.
- Run `python3 Scripts/finish_test_run.py --apply` with each explicitly used `--simulator UUID` and completed marked `--build-cache PATH`. Shut down only devices this run booted, then clear their regenerable wallpaper snapshot scratch. Never erase app/device data or touch other projects’ active devices. The wallpaper cache was measured at 22 GiB across Taskfold test devices on 4 November.
- Reuse one stable derived-data cache per platform/destination and build purpose (daily use or isolated acceptance), rather than one directory per attempt, and a fixed phone/tablet pool. Keep compiler caches within 768 MiB per selected cache; prune them when free space is below 30 GiB. Keep the 20 GiB hard preflight floor. Serialize heavy builds.
- Retain the current verified app package and one rollback, concise test outcomes and necessary failure evidence. Retire superseded candidate packages and duplicate products only after verified archive/evidence preservation. Never delete source, real task data, Keychain items, Docker volumes, swap, shared device-support files or unrelated projects as routine end-of-run cleanup. Review shared regenerable caches separately when required.
