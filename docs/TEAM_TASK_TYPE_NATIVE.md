# Shared heading native controls

26 October 2026. Both owned apps now connect their existing Task/Heading picker
and the subtask organizer’s Make heading / Make task action to captured shared
capabilities and live edit access. Normal client flags and hosted rollout remain
off. Source service contracts are in TEAM_TASK_TYPES.md and TEAM_TASK_TYPE_LIFECYCLE.md.

## Behavior

A shared type control needs the client opt-in, both captured edit/lifecycle
protocols, both current protocols, the matching account/origin/project/team and
current manager/editor access to an active, unarchived project. The editor also
retains its captured workspace, session, source and access-token admission. The
Store rechecks live authoring availability before committing a type mutation.
Missing or future capabilities do not create an ordinary-writer fallback. Personal
local type controls retain their existing client gate. Normal app Info settings
are unchanged; isolated test copies enable the flags explicitly.

Root choices use the existing draft editor. The organizer preserves a subtask’s
notes, identity, descendants and other fields when changing its type, and disables
the action for a currently completed item. Its Save still returns to the parent
editor; the parent’s normal Save/autosave remains authoritative. Existing known
heading status and ordinary sibling checkboxes retain the native appearance.
Completed-item reopen/type combinations still need wider native acceptance.

The old imported-heading review now shares the same captured authority as the
picker. No provider request, import rollout or source metadata reinterpretation
is added. Capability/access changes pause the editor and preserve unsent work in
the existing private encrypted draft path. Failed persistence keeps the choice
and permits an explicit Save retry.

## Undo fix found by native testing

A fresh Undo/Redo intentionally rebases its baseline to the current row. The Store
previously filled only changed fields before calling completion capture, leaving
required completed/completed_at context missing on a type change. Both Stores now
use TaskCompletionRevision.editBaseline for that fresh baseline, which retains the
full type/completion/revision/generation cohort (and existing recurrence context).
Captured partial baselines are not silently repaired or granted new authority.
The installed shared conversion/Undo/Redo case reproduces and verifies this fix.

## Verification

Each repo passes 141 selected Core cases, including live/captured capability,
opt-in, role and origin gating. The current-source unsigned Mac app builds; the
isolated iOS app/widgets/UI runner build and strict/deep signature checks pass.
Five installed scenarios pass independently on iPhone and iPad Simulator:

- Root draft Cancel, Save, exact unrelated-field preservation, scoped typed queue,
  Undo/Redo and cold queue preservation.
- Nested heading action in the real organizer, preserved ordinary sibling and
  opaque child data, one root-scoped tree command and cold preservation.
- Missing heading capability keeps the type control hidden and leaves work intact.
- Capability pause after choosing Heading keeps the source/queue unchanged and
  reports the draft privately preserved before closing the stopped editor.
- New shared heading, failed persistence, retained choice, explicit retry, one
  scoped POST and cold preservation.

All four root/organizer images were inspected. This fixture deliberately pauses
sync; Save verifies native admission, durable local intent and queue isolation,
not actual server delivery or hosted acceptance. Prior isolated SQL contracts are
separate evidence, not a substitute for end-to-end native transport testing.

The current Mac app and UI runner also build with the verified existing Apple
Development team and pass strict/deep app signing checks. Its actual runtime
attempt exits 65 before any test case: Xcode’s test manager timed out enabling UI
automation mode. This is not an app acceptance pass. No debugger authorization or
system setting was changed. The signed current-source harness is retained in
/tmp/taskfold-native-types-mac-host and /tmp/taskfold-native-types-mac-native-build.
The expired authorization question requires no action on a stale prompt.

Remaining: Mac runtime/keyboard/window acceptance, full native delivery and receipt
recovery, source/account races, completed-item reopen combinations, native lifecycle
and bulk recovery, spoken/largest-text, installed widgets and cross-device checks,
and shared template/import adapters. Normal rollout and user-deferred upgrade,
provider, notification and distribution work remain unchanged. Rank 3 and Px stay
active. Exact results and initial failures are in shared-heading-native/.
