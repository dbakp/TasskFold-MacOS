# Current P0 release gates

Current checkpoint: 9 October 2026. This is the execution order for the remaining work, not a replacement for the full widget/Todoist scope or the historical implementation evidence. An implemented feature is not automatically accepted for release.

| Gate | Evidence now | Next acceptance work | External dependency |
| --- | --- | --- | --- |
| Native data continuity | Two isolated iOS clients pass online edits and both offline conflict choices, including a later queued estimate; Mac transport reads the result. | Deletion/recurrence, organization/settings, restore, membership revocation and mixed-version preservation; actual Mac user flows. | Mac GUI execution remains disallowed pending explicit permission. |
| Installed widgets | Small iOS My list passes selection, task routing, warm/background completion and privacy. | Cold-app completion, independent instances, remaining families/sizes, account changes and Mac/physical hosts. | Mac GUI permission; physical devices and provisioned release inputs. |
| Todoist migration | Current importer and native response handling have fixture/transport evidence. | Actual isolated provider-account import, persistence and retry without duplicates. | A disposable Todoist account with suitable provider access. |
| Remote reminders | Native authority handoff, registry, queue and disabled provider worker are implemented. | Real signed registration, APNs acceptance, closed-app delivery/actions and local/remote handoff on physical devices. | APNs signing configuration location requested; no physical iPhone/iPad is currently available to developer tools. Do not enable rollout based on fixture success. |
| Calendar integration | Actual iOS EventKit permission, selected local event, privacy, relaunch and disconnect pass. | Denied-permission recovery through Settings, external calendar provider and Mac/physical behavior. | Mac GUI permission and physical/provider access. The Simulator currently opens Settings at its root. |
| Public Mac distribution | Packaging integrity checks and Developer ID pipeline implemented. | Signed app/widget export, notarization, installation and actual host access. | Developer ID identity, profiles and notarization credentials. |
| Remaining requested parity/usability | Detailed implementation contracts and native/Core evidence exist. | Complete outstanding grammar/hierarchy and full-surface accessibility acceptance after data/delivery gates; retain original scope. | Some final checks require Mac runtime and real devices. |

## Live remote-reminder checkpoint

A read-only query of project `zqxflydiyfjeedqvyova` on 9 October returned:

- `taskfold-native-reminder-sweep`: schedule `30 seconds`, `active=false`.
- `taskfold_private.reminder_authority_rollout`: version 1, `enabled=false`.
- Unexpired pilot accounts: 0.

No scheduler, rollout, pilot, account, device or secret was changed. This proves the rollout is gated; it does not independently inspect the Edge secret values or establish APNs delivery. `xcrun devicectl list devices` reported physical phones/tablet unavailable and test Simulators connected. No installed Mac app was launched.

## Work discipline

Close the release gates using actual user workflows and fix failures they expose. Reuse the existing isolated build caches; run focused checks when production changes are narrow, without repeating unrelated full matrices. Commit and push completed work to each owning repository. Record blocked external requirements separately so they do not trigger more substitute fixture tests. The full objective remains active until the complete acceptance scope is proved.
