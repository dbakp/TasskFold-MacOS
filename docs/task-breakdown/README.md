# Reviewed on-device task steps — 5 November 2026

## Implemented

The task editor/inspector offers **Suggest steps** in Subtasks. It opens a separate editable description initialized from the task title; descriptions, attachments, account details, dates and existing checklist content are not sent to the model. Generation starts only after the user selects Suggest steps. Apple’s SystemLanguageModel generates 3–8 structured action titles on-device. Cloud providers, credentials, network services and system settings are unchanged. Unsupported/disabled/not-ready models and unsupported locale states have explicit messages; manual subtasks stay available.

The review lets users edit, exclude or delete steps with explicit remove controls, retry generation, Stop, Cancel or **Add selected**. Invalid description/selection warnings explain disabled actions. Editing the description clears previous suggestions and cancels an active generation. Validation warnings explain disabled application. Selected titles must be distinct, short plain-text single lines, bounded to 12 steps and 1,200 UTF-8 bytes/300 characters per title. Description input is bounded to 2,000 UTF-8 bytes and output generation to 768 tokens. The model receives no tools. Metadata-like text is treated literally, never passed to natural-language task capture. Applying constructs all new child rows before updating the ordinary editor draft, retaining original children and all other fields. Normal creation, permissions, recovery, save and history paths still own persistence. On iPhone/iPad this applies to the editable task draft; Mac retains its existing autosave behavior, finishing pending edits before capturing the request.

A request binds the exact original task, workspace incarnation and authenticated session. Changed source/project/generation/completion/notes/checklist/opaque fields, changed sessions, account switches and same-account reincarnations refuse application. Superseded, cancelled and closed generation tokens refuse late results. The sheet hides task content and closes when its source becomes unavailable; backgrounding stops generation. Cancel adds no steps. No proposal is persisted or applied automatically. No normal rollout gate is changed.

## Verification and remaining work

Each independently owned Core suite has **40 passes, 1 explicit skip, 0 failures** across 41 selected cases. Eight new contract cases cover literal titles/fresh identities, exact prefix preservation, atomic failure, changed source and Unicode spelling, account/session fencing, bounds/depth, duplicate application and late/cancelled generations. Existing checklist and voice-draft cases are included. [Own result](core-verification.json).

The opt-in real-model probe uses only “Prepare a small picnic at a local park” and makes no task writes. On this Mac, SystemLanguageModel reports Apple Intelligence is disabled. **No real generation was accepted.** System settings remain unchanged. [Current signed app builds](signed-build.json) compile and pass strict signature checks. FoundationModels is weak-linked in both binaries; older-system launch has not been tested. [Cleanup](cleanup.json) and [Core caches](core-cache-storage.json) retain all four selected caches below 768 MiB. No Simulator or test app was launched for this milestone. Native normal/large-text/VoiceOver review, actual generated-quality/latency, save/Undo/cold recovery and account-switch screen checks remain pending. Build/Core evidence does not substitute for these checks. The Mac remains locked; the physical phone was last unavailable. Phone34 was subsequently installed from the earlier frozen optimized archive; these new source changes remain excluded. Mac14 remains installed and Mac22 remains prepared. [Phone installation](../daily-use-build/phone-34-installation.json).

The independently stored child-record rollout remains gated; this milestone does not accept generated insertion against that contract. Filter suggestions are now implemented separately, with their own [scope and pending acceptance](../filter-assistance/README.md). The user chose on-device assistance only on 5 November; no cloud provider or cloud fallback is planned. Native generation and the remaining acceptance work still need completion.

## API basis

Apple’s [Foundation Models generation guide](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models), [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation) and [language/locale guidance](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models) were reviewed alongside the installed Xcode 27 SDK interfaces. Runtime use is guarded for iOS/macOS 26; model availability and locale support are checked before inference. This is the on-device SystemLanguageModel, with no cloud fallback.

## 6 November — independent child-step service foundation

A separate atomic reviewed-step service now exists behind a default-Off gate. Its owning full-schema checks pass, but the current editor review is not yet connected to it; typed requests, saved recovery/history and native acceptance remain. See [current implementation and gaps](../reviewed-step-batches/README.md). Further physical iPhone installation is deferred; suggestions remain on-device only.

## 6 November — saved-record review and encrypted recovery built

The saved-subtask organizer now has a separate root/nested on-device review, atomic selected Add, encrypted cold retry/check/stop and a dedicated one-batch Undo. It does not silently save surrounding drafts. Owning client/service checks and signed builds are recorded in [reviewed step batches](../reviewed-step-batches/README.md). Native Store/Backend/screen acceptance, genuine generation and global Undo/Redo integration remain; no normal gate or installed app changed.

## 6 November — normal history and production-store recovery

Confirmed saved-record additions now enter normal Undo/Redo, with durable exact inverse lineage and fresh original-slot Redo. Consecutive reversals preserve unchanged added steps and unrelated live container contents. Owning current client, service and production-store results are in [reviewed steps](../reviewed-step-batches/README.md). Actual review-screen/keyboard/accessibility and genuine model acceptance remain; installed apps and normal gates are unchanged.
