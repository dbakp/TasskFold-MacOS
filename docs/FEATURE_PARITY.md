# Feature parity and remaining work

## Parity pass — 11 September 2026

Compared against `dbakp/taskfold-ios` at `d7a8bec` (shared Core adopted, not re-implemented). Everything below is in the Mac app unless marked.

| iOS capability | Mac status | Notes |
| --- | --- | --- |
| Priority-band ordering (`DayPlacement.arranged`) | Done | Today, each Upcoming day, Inbox, projects and sections, labels, calendar day panel. "Priority" sort removed; Due Date and Title remain. |
| Band-constrained drops (`DayPlacement.constrained`) | Done | The insertion indicator is drawn at the constrained slot; "Stays with P2" hint with one trackpad tick when the pointer is over another band. |
| Manual reordering in non-day lists | Done | Device-local keys `group:<projectID>:<sectionID|none>` and `scope:<preferenceKey>`, one undoable commit per move. Dropping into a section adopts it. |
| Quick-entry tokens as chips (`QuickEntry.tokens`, `disabled:`) | Done | Quick-add bar (lists and Calendar) and the inspector title. ✕ declines a group; Tab, Space, Delete, Escape work on chips. |
| Links by page title (`NSDataDetector`, `LPMetadataProvider`) | Done | Rows and notes render links in the accent colour; hover preview (`LPLinkView`); Open / Copy Link / Share; inspector Links section. A link click never selects the row. Opens in the default browser (iOS uses an in-app Safari sheet). |
| Account: change email / password, reset email, delete account | Done | Settings ▸ Account ▸ Security, sheets surface server errors verbatim. Needs a live account to exercise; unverified against Supabase here. |
| Actionable reminders (`ReminderCategory`) | Done | Registered at launch; Complete, Remind me in 1 hour, Move to tomorrow handled in the notification delegate. |
| Plan Your Day / Review This Week | Done | One card at a time with T, M, D, Space, → shortcuts; ⌥⌘P / ⌥⌘W; toolbar buttons in Today and Upcoming. |
| Eight accent colours (`Color.accents`, `accent` key) | Done | Settings ▸ General; the scene tint and every accent-coloured element follow the choice. |
| Tagline copy removed | Done | Today shows a date line and a count. |
| Recent searches | Done | Suggested in the global search field (shared `recentSearches` key). |
| Siri / Shortcuts intents (`Intents.swift`) | Done | Shared file compiled into the Mac target; Add Task, What's Due Today, Complete Task appear in Shortcuts via `Metadata.appintents`. |
| Today widget (App Group snapshot) | Done | `TaskfoldWidgets.appex` embedded, small / medium / large. `group.com.dbakp.taskfold` provisioned on the personal team without issue on this Mac. |
| Live Activity / Control Center button / Lock Screen families | Not applicable | iOS-only surfaces. A no-op `LiveActivityManager` satisfies the shared persist hook on macOS. |
| Swipe actions, mobile pill mode switcher, iPad sidebar | Not applicable | Mac uses keyboard, context menus, and the split view. |
| `Store.startLocal` "Getting started" seed | Done | Shared; Mac wording comes from the Core's `os(macOS)` branch. |

Verification: see the 11 September parity entry in `PREMIUM_MAC_PLAN.md`.

## Original audit — 10 September 2026

Audit date: 10 September 2026. Compared the Mac implementation with the original web app (`dbakp/taskfold`, commit `17c12da4399c2d253259c565fa2ff18f973a31b5`) and shared iOS app (`dbakp/TaskFold-iOS`, commit `9419eb230c7cd91bce0a213206ae84c2dc5deb70`).

## Restored access in this update

The earlier Mac source already included the following screens. Their entry points were buried in Settings, and local mode offered no direct sign-in action. The earlier polish commits did not delete these implementations.

- **Account and login:** sidebar account menu and Account menu-bar commands. Sign in/create account and Google sign-in can be opened from local mode without first leaving the local workspace. Local data remains in its separate existing cache.
- **Profile:** display name, avatar upload/removal, account identity, and sign-out remain in the Account tab.
- **Settings:** a visible sidebar entry and native ⌘, window; start view, appearance, reminders, notification settings, manual sync, pending-sync information, and JSON export remain available.
- **Todoist import:** a dedicated Import tab and direct menu entries replace the nested Sharing tab. Signed-out/local users have a direct sign-in action. Signed-in users retain the existing preview-before-import flow for projects, sections, labels, tasks, subtasks, and comments.
- **Invitations:** a dedicated tab and direct menu entry. Existing accept/decline and project collaborator management remain available.
- **Selected-row readability:** full-opacity priority and action controls, selected foreground colors, and cleanup of drag state after release/cancellation. The table already draws the native drag image; a second row-wide fade is no longer applied.
- **Image comments:** Cmd+V in the comment editor creates an image-only comment immediately, matching `src/components/TaskComments.tsx` in the web app. It uses the existing attachment schema and 5 MB limit, preserves unfinished comment text, shows an inline thumbnail, and opens Quick Look on click.

## Retained functionality

Task creation, notes, dates/times, priorities, recurrence, subtasks, labels, project sections, attachments, text comments, completion, duplication, bulk actions, undo/redo, offline persistence, sync, drag-and-drop day placement, and calendar modes continue to use the existing Mac/shared implementation.

The web PWA installation flow and browser push-subscription controls are platform-specific. The Mac app uses native installation and macOS reminders instead.

## Prioritized follow-up plan

1. **Combined filters:** match the web `FilterButton.tsx` with project selection, multiple labels, has-date/has-label toggles, and a visible reset action. Preserve these per destination and test interactions with global search.
2. **Label merging:** add the web `LabelsSettings.tsx` merge flow with a preview of affected tasks, one reversible change, and no duplicate labels on tasks.
3. **Avatar cropping:** replace the current automatic center crop with an interactive crop preview comparable to `ImageCropModal.tsx`. Keep the existing resize/upload limits.
4. **Profile preferences:** define how the web's synchronized theme/notification preferences interact with Mac-specific settings. Keep OS notification permission separate from application preferences.
5. **Deeper parity validation:** exercise live Google/email authentication, avatar upload, invitation responses, and a preview/confirmed Todoist import using a dedicated account and disposable import data. UI coverage does not prove external provider/network behavior.
6. **Continue the premium Mac plan:** global capture, progressive inspector disclosure, focus/motion/accessibility checks, and performance profiling with larger datasets are tracked in `PREMIUM_MAC_PLAN.md`.

Password reset, changing account email/password, and account deletion were not found in the reviewed original web settings/auth screens. Treat them as new account features to design, rather than functionality removed by the Mac polish work.
