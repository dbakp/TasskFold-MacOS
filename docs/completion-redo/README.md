# Completion Undo and Redo

31 October 2026. The combined parent/subtask completion path now has a fresh, guarded Redo and an asynchronous history bridge. The wider storage migration remains unfinished and disabled for ordinary use.

Redo starts from a confirmed whole-selection Undo. It reads the selected roots and subtasks again, checks generation, project, node incarnation and completion cohorts, and creates fresh group/member identities. Changed completion counters, replaced children and older reads refuse the action. Unrelated current titles and notes are preserved; they are never copied into the saved request. The original root completion clock and time zone are retained. The existing child forward endpoint stamps its fresh server time; aligning all activity timing remains part of the unfinished shared-history work. Selected no-op guards remain part of the request. Each fresh request uses the existing encrypted journal before sending; interrupted retries retain that exact request.

The bridge registers the native inverse synchronously while UndoManager is undoing or redoing. It fills the next step only after confirmation and fences late callbacks by workspace and bridge generation. Immediate local actions stay synchronous. The iOS Store owns the shared ordering for its menu, toast and other local Undo controls; older controls cannot bypass newer retained actions. Mac keeps the native responder chain for text editing and observes editor/history changes so keyboard command validation does not stay stale.

## Verification

Each independently owned repository passes 53 focused Core tests, including six bridge cases and three Redo cases. These tests cover typed confirmations from the existing actual-PostgreSQL fixture, completion cycles/replacement/older-read refusal, exact uncertain-request persistence/retry, pending confirmation, history ordering, scope changes and synchronous local actions. Core package tests exclude Store; native checks cover the app handoff separately.

Final Mac v3 passes keyboard text Undo/Redo/Undo, combined completion/Undo/Redo/Undo, original notes and untouched-sibling preservation, then quit/cold-return preservation. Four unique confirmed peer operations leave the root and selected child open at completion version 4. The app is closed afterward. See mac-native.json in the Mac repository. iPhone and iPad v7 pass the same journey and cold return. Each peer records exactly four requests, four writes and four unique decisions; the selected child reaches completion version 4 while its untouched sibling remains byte-for-value unchanged. The iPhone v9 local-history regression also passes stale-button refusal at 30 entries, exact action resumption and normal Redo. Eight mobile screenshots were reviewed. Failed/preflight phases remain recorded rather than represented as passes.

Native journeys use a reserved synthetic HTTP peer and isolated app identity. They establish UI, Store, persistence and lifecycle behavior, not new hosted SQL acceptance. No wire protocol, server implementation, hosted configuration or normal-use gate changed. Existing server authority evidence is in mixed-task-completion-native; this milestone does not claim a newly run database suite.

## Remaining scope

Redo for standalone child/batch paths and other newer operations, consistent shared activity history, older-data/history mapping, shared file/discussion custody and broader account/window/background/speech/large-library acceptance remain. Redo history itself is not restored as an active menu stack after quitting; uncertain fresh requests remain reachable through saved recovery. Existing rollout, provider, distribution, audio and physical-device deferrals stay paused.

The Mac still emits the previously observed NSTableView reentrancy warning in this fixture. This acceptance proves the recorded controls and saved outcomes, not the absence of every native warning.
