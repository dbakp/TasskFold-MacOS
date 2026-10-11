# P0 progress snapshot — 11 October 2026

**Feature implementation is largely complete. Release acceptance is incomplete.**
This short view summarizes `P0_RELEASE_STATUS.md`; its dated entries and JSON evidence remain authoritative for exact scope. A passing build is not native workflow acceptance. No percentage is assigned because remaining gates have very different risk and effort.

| Area | Proven progress | Remaining gate |
| --- | --- | --- |
| Productive widgets | Twelve kinds implemented; many installed iPhone/iPad configurations, cold/warm routes, completion, account switches and app privacy controls verified | Installed Mac hosts; remaining supported sizes/conditions; system privacy redaction |
| Todoist import | Real read-only multi-page import and replay; native imported-workspace handoff; iPhone lost first-import and replay-response recovery | Native Mac discard/retry |
| Recovery | Native portable export/restore, encrypted Mac safety copy, cloud and cross-account restore/replay/relaunch | External provider-backed file transfer and remaining failure boundaries |
| Device continuity | Native Mac ↔ phone tasks/notes/planning/organization round trips, offline edits and relaunches | Remaining concurrency/legacy-client variants; authenticated native Mac attachment receipt; paired profile receipt |
| Core usability | Capture/editor/subtasks/completion/Undo fixes; Mac calendar keyboard navigation; scoped phone/tablet normal and largest-text calendar routes | Spoken VoiceOver; four retained clipping findings; remaining critical landscape/sidebar flows |
| Notifications | Mac Focus authorization, scheduling, pause/resume and background banner evidence | Actual notification Open/action/terminated/account-change journeys; real APNs delivery and rollout proof |
| Distribution | Independent repositories and development builds | Installed Mac widget provisioning; Developer ID/notarization and distribution signing |

## How to interpret recent activity

Recent work includes actual user-visible calendar/accessibility fixes, native workflow verification, test-driver corrections, signing/Simulator problems and evidence maintenance. These are different kinds of progress and should not be combined into a claim that all P0 is done. Calendar coverage is bounded; additional combinations are not automatically new release requirements.

## Next execution order

1. Scoped landscape Today task/Search/rotation and capture checks now pass normal/largest native cases (`landscape-today-evidence.json`). General long-row visibility and keyboard-visible composer polish remain open. Move next to the import/notification gates rather than additional calendar combinations.
2. Finish native Mac discard/retry (its running binary predates the hook), then real notification actions. iPhone first-import response-loss recovery now passes (`first-import-recovery-evidence.json`).
3. Complete critical accessibility/attachment journeys, then the outstanding installed widget hosts.
4. Close APNs and distribution gates with actual credentials/signing/delivery evidence. Revalidate current availability before describing any external prerequisite as blocked.

Ordinary iPhone/iPad acceptance uses Xcode Simulators as requested. Actual remote delivery and distribution remain separate gates. Todoist source data must remain unchanged. Each repo owns its code and release inputs; completed work is committed and pushed separately.
