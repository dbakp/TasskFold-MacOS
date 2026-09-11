# Feature parity and remaining work

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
