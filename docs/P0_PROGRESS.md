# P0 progress snapshot — 12 October 2026

**Feature implementation is largely complete. Release acceptance is incomplete.**
This short view summarizes `P0_RELEASE_STATUS.md`; its dated entries and JSON evidence remain authoritative for exact scope. A passing build is not native workflow acceptance. No percentage is assigned because remaining gates have very different risk and effort.

| Area | Proven progress | Remaining gate |
| --- | --- | --- |
| Productive widgets | Twelve kinds implemented; many installed iPhone/iPad configurations, cold/warm routes, completion, account switches and app privacy controls verified | Installed Mac hosts; remaining supported sizes/conditions; system privacy redaction |
| Todoist import | Real read-only multi-page import and replay; native imported-workspace handoff; iPhone lost first-import and replay-response recovery; Mac lost replay-response Retry and relaunch | Named native import/retry gate closed; evidence retains exact scope |
| Recovery | Native portable export/restore, encrypted Mac safety copy, cloud and cross-account restore/replay/relaunch | External provider-backed file transfer and remaining failure boundaries |
| Device continuity | Native Mac ↔ phone tasks/notes/planning/organization round trips, offline edits and relaunches; paired name/photo and native Mac attachment handoffs | Remaining concurrency/legacy-client variants |
| Core usability | Capture/editor/subtasks/completion/Undo fixes; Mac calendar keyboard navigation; scoped phone/tablet normal and largest-text calendar routes | Spoken VoiceOver; four retained clipping reports (photo/note/chip, not four confirmed visible defects); remaining critical landscape/sidebar flows |
| Notifications | Mac Focus authorization, scheduling, pause/resume and background banner evidence | Actual notification Open/action/terminated/account-change journeys; real APNs delivery and rollout proof |
| Distribution | Independent repositories and development builds | Installed Mac widget provisioning; Developer ID/notarization and distribution signing |

## How to interpret recent activity

Recent work includes actual user-visible calendar/accessibility fixes, native workflow verification, test-driver corrections, signing/Simulator problems and evidence maintenance. These are different kinds of progress and should not be combined into a claim that all P0 is done. Calendar coverage is bounded; additional combinations are not automatically new release requirements.

## Next execution order

1. Scoped landscape Today task/Search/rotation and capture checks now pass normal/largest native cases (`landscape-today-evidence.json`). The strengthened named saved-capture row checks also pass functional assertions, but a background-thread publishing warning prevents clean-run acceptance (`saved-capture-access-evidence.json`). General long-row visibility and keyboard-visible composer polish remain open. Presented Search now also passes unfiltered normal/largest placeholder/query audits after shortening its visible prompt (`presented-search-audit-evidence.json`). The refreshed four other reports remain retained. Move next to the import/notification gates rather than additional calendar combinations.
2. Native Mac replay response-loss/Retry now passes in the fresh signed current-source app (`mac-import-retry-native-evidence.json`); its obsolete waiting launch is retired and needs no further approval. Move to real Mac notification actions. iPhone first-import response-loss recovery retains its accepted scope (`first-import-recovery-evidence.json`).
3. Complete critical accessibility/attachment journeys, then the outstanding installed widget hosts.
4. Close APNs and distribution gates with actual credentials/signing/delivery evidence. Revalidate current availability before describing any external prerequisite as blocked.

Ordinary iPhone/iPad acceptance uses Xcode Simulators as requested. Actual remote delivery and distribution remain separate gates. Todoist source data must remain unchanged. Each repo owns its code and release inputs; completed work is committed and pushed separately.

## Latest closed gate

12 October: native Mac → iPhone → Mac profile name/photo handoff now passes, including both normal process relaunches. Exact server baseline and original profile are restored; primary phone/iPad data are unchanged. See `profile-pair-evidence.json`. No new production fix was needed.

12 October: named native Mac replay response-loss/Retry now also passes, including actual quit/relaunch and exact preservation. Fresh stable development signing removes the preceding import-launch approval friction. The initial NSTableView warning remains open.

12 October: authenticated native Mac attachment handoff now passes through iPhone preview/relaunch, a phone notes edit and Mac foreground sync/relaunch/preview. The small PNG remains byte-for-byte and metadata-identical. Native cleanup restores all 14 non-activity server tables; two synthetic creation/deletion ledger entries remain. See `attachment-handoff-evidence.json`. External file-provider transfer remains open.
