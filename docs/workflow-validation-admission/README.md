# Admit worker-validated workflow creation — 28 October 2026

Fresh local workflow workers already append every proposed row through `FreshWorkflowCreation`, which performs the generation and task-kind checks. The Store previously rebuilt the fresh identity plan and repeated those checks on the main actor. The worker now retains its unconsumed append plan and computes the heading-authoring requirement with the same `TaskKind.requiresAuthoring` function. It also explicitly runs captured-type validation.

A validation result is available only with complete prepared projection/encoding and retained Undo, an unchanged normalized command buffer, the same source revision and raw account, and the existing workspace-cache/calendar admission. The Store checks the current heading-authoring setting before reusing that result. It never captures permission in the worker. Unsupported kinds, collisions, modified buffers, non-encodable data, missing Undo and stale context keep the ordinary path. Shared/cloud mutations do not receive this local-only admission.

All preceding account-removal/recovery, role, receipt, history-table, organization and batch gates remain on their existing Store paths. Final scope admission, receipt staging, exact encoding admission, durable-baseline decoding, atomic writes and failed-save rollback remain in place. Late projection rejection replays every command using the retained, unconsumed fresh append plan. No persisted contract, global cache, release gate or user-visible control is added.

## Diagnostic observation

The existing 5,000-task synthetic iPhone Simulator case passed once on the previous commit and once on the changed source, with temporary phase timers only in the disposable host. Neither run overlapped our Core tests or native build jobs. These are single Debug observations, not statistical or physical-device performance acceptance.

| Phase | Previous | Changed |
|---|---:|---:|
| Fresh-creation admission and row-validation phase | 216.71 ms | 21.63 ms |
| Entire synchronous commit | 423.68 ms | 222.04 ms |
| Background history/preparation | 1.139 s | 1.113 s |
| Widget ready | 3.865 s | 3.495 s |

Other phases fluctuate. The direct change removes repeated creation admission/static task checks from the main actor for an exactly admitted local projection. It does not remove validation from workflow creation. The remaining approximately 0.22-second synchronous save, production rendering, richer children/assignments and hosted/paired delivery remain open.

Instrumented Store/fixture inputs, source hashes, implementation patches, build/signing logs, executable hashes, exported attachments and strict result summaries are retained here. The previous debug dylib hash was recovered from the still-installed baseline app before its replacement; its validation symbol was absent, and the changed binary's symbol was present. These code hashes supplement the app-loader and test executable hashes. Timers are removed before final builds, whose relevant source files are byte-equal to their respective repositories. The diagnostic `repoCommit` is the parent revision; the changed working-tree patch and hashes identify the after input.

## Functional verification

Both independent Core suites pass 159 selected tests. Six new cases cover 648 task/checklist-kind, completion, timestamp and current-authoring comparisons; exact-buffer/source/account/calendar refusal; raw Unicode/signed-zero edits; current capability changes; unconsumed task/project-only fallback plans; collisions, unsupported commands, absent Undo, encoding failure and cancellation. The broader selected corpus retains workflow, heading, generation, history, body-size, destination-index, widget-preparation and encoding checks.

Six final iPhone cases and one iPad case pass the strict verifier with no reported runtime warnings. Final native case counts and exact receipts are in `final-verification.json`. The final phone selection covers actual TemplateRunView Create/Undo, a 5,000-task save, changed-source fallback, failed-save history preservation, late rejected task projection and late rejected project-only projection. iPad checks the actual Create/Undo journey. Scale tests now assert whether prepared validation was actually used, including its refusal after a source change. Both apps build and pass strict signature verification. Mac desktop runtime and its existing warning gates remain open; this is not release acceptance.

Real audio, provider setup, remote delivery, older-client rollout and distribution remain explicitly deferred. Full Px completion is not claimed.

The retained diagnostic scripts resolve `HEAD` as the parent recorded in the input receipts. Pin that parent revision when reproducing them from a later checkout, and use new result/receipt paths rather than overwriting the original evidence.
