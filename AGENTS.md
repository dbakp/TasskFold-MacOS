# Working on Taskfold for macOS

- After implementing requested changes, run appropriate checks, commit the changes, and push them to this repository. The user explicitly wants all completed changes pushed, including follow-up fixes.
- This repository owns its Mac code, resources, tests and release scripts. Do not add build dependencies on the iOS repository. Preserve unrelated work in other checkouts; implement and test relevant data-contract fixes in each app repository independently.
- Keep `docs/ROADMAP.md` current as updates land.
- Use isolated debug fixtures for UI tests; do not modify real task data for testing.

- Before heavy local builds, Simulator runs or Docker fixtures, run `python3 Scripts/check_test_storage.py --path /tmp` and require its default 20 GiB free-space floor. Reuse current test hosts/products, run resource-heavy platforms sequentially, and prune approved obsolete outputs after retaining concise evidence. Never reset Docker volumes or erase real app data as cleanup.

## Complete GitHub delivery

- The user requires completed changes to be committed, pushed, and merged every time. Create or update a pull request against the repository’s default branch, wait for required checks, merge without bypassing branch protection, and verify the merged branch contains the completed commit. Pushing a feature branch alone is not completion. Use the same branch name in both repos when an update touches both, and link the two pull requests.
- Keep each app independently owned. Merging source does not authorize enabling deferred rollout gates, publishing a release, changing hosted services, or restarting an installed app with unsaved work.

## Track work in the roadmap

- `docs/ROADMAP.md` is the single plan for both apps (the same file lives in each repo). Tick its items and note decisions there as updates merge; keep the two copies identical.
- Put verification notes in the pull request description (what changed, checks run, screenshots, open risks) rather than new per-change docs, evidence JSON or the retired `px-progress` dashboard. Existing docs stay as reference; do not grow them for routine changes.

## Orchestrated delivery

- The main session orchestrates: it writes briefs, spawns subagents (Haiku for read-only search and triage, Sonnet for builds, tests and implementation), and reviews each report against the real diff and test output before merging. A subagent's "done" is a claim, not proof.
- Subagents return short summaries, not file contents. Run Mac and iOS work in parallel only when independent; serialize heavy builds.

## End every run with storage cleanup

- Before finishing **every run**, check free space and clean completed Taskfold-generated outputs. Record before/after free bytes and what was removed; never leave cleanup as a future promise.
- Run `python3 Scripts/finish_test_run.py --apply` with each explicitly used `--simulator UUID` and completed marked `--build-cache PATH`. Shut down only devices this run booted, then clear their regenerable wallpaper snapshot scratch. Never erase app/device data or touch other projects’ active devices. The wallpaper cache was measured at 22 GiB across Taskfold test devices on 4 November.
- Reuse one stable derived-data cache per platform/destination and build purpose (daily use or isolated acceptance), rather than one directory per attempt, and a fixed phone/tablet pool. Keep compiler caches within 768 MiB per selected cache; prune them when free space is below 30 GiB. Keep the 20 GiB hard preflight floor. Serialize heavy builds.
- Retain the current verified app package and one rollback, concise test outcomes and necessary failure evidence. Retire superseded candidate packages and duplicate products only after verified archive/evidence preservation. Never delete source, real task data, Keychain items, Docker volumes, swap, shared device-support files or unrelated projects as routine end-of-run cleanup. Review shared regenerable caches separately when required.

## Routine Mac updates are already authorized

- On 6 November 2026, the user explicitly instructed: “Never ask me again about this, you just go and install the new version. I'm not working on the app.” Install verified Taskfold Mac updates and restart the Mac app without asking for saved-draft confirmation. Preserve a private safety copy and a verified rollback first.
- This authorization is specific to routine Mac Taskfold updates. iPhone installation remains separately deferred. System dialogs that require the user's password or cannot be reached by computer use may still require a concrete manual action; do not repeat the restart/draft question.
