# Repair reviews that survive closing

A repair choice is saved in the existing account-bound encrypted repair vault before the review accepts it. Closing or restarting the app keeps the ordered changes, generated references, original task/generation/project/workspace identity and exact original review digest. The original opaque tree stays on its existing server read/export path; it is not decoded into a lossy draft representation.

Saved reviews appear alongside saved repair requests. Reopening obtains a fresh authorized original and requires the same identity and digest before replaying the choices for a new preview. Changed, moved or recreated tasks cannot inherit a saved review. The choices remain available to discard explicitly; opening or resuming never submits them. Paused repair gates keep local reviews discoverable without enabling new requests.

Every edit, Undo-last-choice and discard uses a version token under the existing account process lock. A stale window cannot replace or remove another window’s newer review. Queueing the reviewed repair consumes its exact draft atomically with saving the command; a failed or uncertain command remains in the existing saved-request workflow. Other tasks’ drafts survive command attempts, confirmations and history removal. Account cleanup removes drafts with the same encrypted repair file.

The state decoder still reads old request-only files, validates new draft identity and bounded changes, and refuses unknown or malformed content. Existing older binaries refuse the added field instead of silently parsing away the draft; normal repair entry points remain gated. Current-client behavior does not resolve the separately deferred old-client rollout policy.

See verification.json for the final source fingerprints and accepted Core/native scopes. No hosted schema, real task data, credentials or ordinary feature gates are changed. Full Redo/history, mapping, shared content custody and broader migration acceptance remain separate work.

## Recorded native scope

Final v5 Mac controls accept a saved first choice, Close/quit, cold saved-review discovery, exact resume, continued valid preview after a 30-second wait and one explicitly confirmed repair with its complete original unchanged. The iOS repo independently accepts the full save-choice/Close/quit/resume/continue/save journey on both iPhone and iPad Simulators. This uses synthetic HTTP peers; previous actual SQL authority checks are unchanged. Each repo independently passes 47 focused Core checks, including seven new draft cases. Broader real-account, protected-storage, paused-gate, window, background and spoken acceptance remains separate. The Mac walkthrough exposed and fixed duplicate list-row identity and routine-snapshot preview invalidation; earlier builds are not final acceptance.
