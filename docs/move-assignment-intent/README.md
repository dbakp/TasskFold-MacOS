# Explicit assignees during project moves

Reviewed 1 November 2026. Each repository owns its implementation, tests and migration candidate independently.

## Result

A project change clears the old assignments. A person deliberately chosen in the destination remains an authored choice, even when it is the same person assigned before the move. Normalization follows the predicted state of earlier commands in the group, including a newly created task's generation. Root move/assignment Undo and Redo use that same ordered model; they retain valid source section/owner restoration and use fresh move request identities.

A scoped assignment binds the original project and task generation. Its project field is a condition, not another move. A moved/replaced task cannot receive that queued assignment through cache projection, saved-history replay or Keep my edit. Undo also refuses to replace a later assignee. Discarding an unaccepted move removes its immediate dependent assignment while keeping later independent notes. The conflict screen explains the unavailable scope and disables Keep my edit for that case.

The guarded `taskfold_assign_task_scoped` endpoint is an authenticated SECURITY INVOKER wrapper with an empty search path around the existing task editor. The migration preserves the editor's authorization, locking, generation and ordinary merge checks, and adds strict project/assignee conditions before merging. Companion note edits roll back on an assignment conflict. Retrying a lost reply accepts the already-saved desired assignee. Missing or overwritten server support fails closed and retains the saved choice; the new client does not fall back to the old endpoint.

## Evidence

- `core-tests.log`: 131 focused Core tests, no failures or skips, independently run in this repository. Includes 17 new intent/history/persistence cases and five transport cases alongside existing assignment, history, pinned-note and tree checks.
- `database-verification.json`: 101 actual assertions in this repository's disposable PostgreSQL fixture using authenticated actor/session contexts. Covers delayed project scope, exact root/child preservation on refusal, lost-reply replay, Inbox owner restoration, foreign-recipient refusal, task-generation refusal, companion note rollback, explicit review, old/missing/overwritten guard refusal, migration reapplication and invoker/anonymous grants. No additional advisor findings; owned container removed.
- `verification.json`: exact source/build/native scope and hashes. `phone/` and `ipad/` retain a passing native summary/log, five exact saved snapshots and their independent verifier results. Ordinary project and assignee controls, Undo/Redo and full cold return pass on both Simulators. Both repositories independently verify the ten mobile snapshots. The two earlier Mac attempts stopped at popup dismissal/inspector re-entry. That gap is now closed by the current Mac/iPhone/iPad native proof linked below, including explicit destination assignment, Undo/Redo and cold return.

The original no-op project field was reproduced as insufficient on the old generic merge: it retained the newer project and accepted a delayed assignment. The server candidate addresses that observed failure. A first subsequent SQL attempt reached the new behavioral checks but stopped at a test-report boolean parsing error; the corrected final 101-assertion run passed. The first app build found two debug-fixture callers missing the newly required throwing-history handling; both are corrected.

## Limits and next work

- No hosted deployment, production data changes or normal-use gate changes. New scoped cloud assignments require the candidate endpoint before rollout. These tests do not establish genuine hosted multiaccount delivery.
- The project move and its follow-up assignee remain two queued server transactions. A confirmed move can leave an assignment requiring retry or review; no cross-request atomicity is claimed. The companion-note rollback assertion concerns one guarded assignment request.
- Previously saved unscoped queues and older clients retain their former path; the separately deferred safe-upgrade rollout is not closed here.
- This proves root assignee intent/history in the recorded scope. It does not restore historical child recipients after a project move, close recurrence/lifecycle histories, or finish broader legacy/cache/editor migration and shared file/discussion custody.
- Native accessibility speech, stale/conflict screen interaction, largest text, multiple windows/accounts and large-library behavior are separate acceptance scopes.

The first Mac native attempt confirmed the move but then tried to assign through the old source-bound inspector. That editor intentionally pauses after its project changes. A second attempt tried clearing selection and reopening current details, but stopped before cleared selection was verified. At that stage the test was still work in progress; neither attempt relaxed the editor’s project, generation or workspace guards. The current follow-up below supersedes that unfinished acceptance status.

## Current follow-up

The Mac native gap is now closed in the recorded local scope. [Current source, builds and native evidence](../inline-subtask-preview/README.md) also includes the read-only preserved-title fix in both apps, 115 focused Core checks per repo, actual title/disabled-control/source-byte assertions and independently verified Undo/Redo/cold return on all three destinations. The earlier 131 Core/101 database runs and failed attempts above remain their historical evidence; the database was not changed or rerun for this display follow-up. This does not close the broader migration or deploy the server guard.
