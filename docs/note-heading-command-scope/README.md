# Note heading commands and task priority

A manual CUA walkthrough in the frozen isolated Mac app reproduces a command collision: the first Command-Option-1 changes the synthetic task priority from 4 to 1 without formatting the note. After opening Text style once, the heading shortcuts work. Bold, Italic, Strikethrough, ordinary Return and Command-Return were observed separately. This is a real failure, not a passing keyboard result; the normal installed app was not modified.

The Mac source now gives the active note a scene-focused command context. Its Text style commands replace the task Priority shortcuts while that context exists, including disabled formatting under Link or Preview. The inline menu no longer registers competing Mac equivalents lazily. iOS attaches the corresponding hardware-key handling to the text editor using SwiftUI input events. Source/session checks and explicit Apply remain. No invisible controls or global event tap is added.

Both SDK builds pass. All current 185 prepared Mac app sources and the owning UI-test source match; actual app/test runner signatures and the executed image freshness are audited. Three Mac keyboard regression cases compile, including fresh heading keys with unchanged task tables, styles/Apply/Undo/cold return, and nested-Link isolation/Cancel. Fixed-build native runtime is still pending the requested desktop unlock. iOS hardware-key and wider speech/account cases remain separate. No fixed-runtime, normal update or full-Px completion is claimed.

The signed products and test plan are preserved after compiler-cache cleanup. Normal Mac 53 remains unchanged; its separate shared-group provisioning followup is still pending. API reference: [SwiftUI input events](https://developer.apple.com/documentation/swiftui/input-events/).

The keyboard implementation remains in the unmerged [draft PR #92](https://github.com/dbakp/TasskFold-MacOS/pull/92). The separate accepted native-save/evidence delivery carries this status record, not the pending keyboard changes. Its build/source receipts describe the preserved isolated product rather than the current main tree.
