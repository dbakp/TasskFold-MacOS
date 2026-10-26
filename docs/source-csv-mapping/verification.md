# Current acceptance

- Owned Core checks: 87 passed, zero failures/skips; 12 new mapping cases.
- iOS: current-source isolated arm64 app/share/widget/UI-runner builds pass;
  deep/strict Simulator signature verification passes.
- Mac: independent unsigned normal Debug app build and current-source isolated
  Apple Development-signed app/UI-runner builds pass; deep/strict signature passes.
- Current-source text mapping scenario passes independently on iPhone 18 Pro and
  iPad Pro 13-inch (iOS 27 Simulator). It explicitly maps title/notes/type, observes
  the ignored Done column, reviews full contents, cancels without table changes,
  revises mapping, saves only a definition, and verifies exact cold persistence.
  Existing task tables stay unchanged; a literal * title remains ordinary.
- Four final mapping/review screenshots were inspected; the iOS repo owns them
  and the final result summaries. Debug-only overlays are not shipping UI.
- The Mac file-mapping and planner cases are compiled/prepared. Native execution
  has not reached the app: automation-mode initialization requires system
  authorization. The failed-start summary is retained in the Mac evidence.
- Mac execution still needs Xcode’s actual Enable UI Automation grant. A separate
  debugger-authorization helper was cancelled without changing its original
  disabled setting; no action is needed on that cancelled prompt. The current
  signed harness stays ready.

The final native reruns use the named modal bar gesture, the labelled type fields,
and the final clock/time-zone preservation guard. Earlier harness failures and
interrupted collectors are explicitly excluded from acceptance (harness-notes.md).
Native Mac, actual picker/provider-backed mapping delivery, spoken/largest-text,
real-device and cloud/cross-device acceptance remain open. No provider, server,
normal heading-authoring, rollout or release configuration changed.
