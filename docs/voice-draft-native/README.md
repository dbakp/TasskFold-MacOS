# Exact voice-draft binding and native review — 27 October 2026

Both apps now require the exact UTF-8 source draft when applying a voice proposal.
Swift String equality treats canonically equivalent spellings as equal; the old
parent and session guards could accept a raw-edited draft. One shared Core helper
now binds the parent adapter and session checks to the exact original text.
Changed text is refused without changing the transcript or saving a task. Existing
request identity, workspace incarnation, recording-token and explicit Apply/Add
requirements remain intact.

The regression reproduces against each old model: 13 selected cases, one failing
case with three failed refusal assertions and 12 passing cases. The composed vs
decomposed Latin, Hangul and combining-mark-order pairs are semantically equal,
but have different UTF-8. After correction, all 81 selected VoiceDraft and
ProjectWorkflows cases pass per repo. They check refusal, exact unchanged-source
output, transcript retention and the existing parser/save/Undo boundary.

## Native acceptance

Two new Mac cases exercise the actual app and TextEditors with the existing
synthetic recorder: partial/final transcript delivery, correction, Cancel keeping
the parent and tables unchanged, Apply changing only draft text, reviewed explicit
Add with parsed date/priority and Inbox destination, preservation of original work,
Command-Z, Redo with only required task-generation changes, normal Quit/cold return
and exact saved-table equality. The synthetic-refusal case retains a corrected
transcript and original draft, supports typed recovery/Apply, then closes the
unsaved parent without writing tasks and verifies unchanged cold tables.

The Mac controller script separately passes 17 checks with its synthetic recorder,
including late permission/result callbacks, cancellation, final correction and the
real one-minute deadline. Its only real-driver invocation has a false context gate
and rejects before permission access. This is not audio/TCC acceptance, and does
not validate the iOS AVAudioSession restoration branch.

On each of iPhone and iPad, three selected native cases pass: corrected transcript
review/Cancel/Apply/explicit save and saved tasks after relaunch; synthetic refusal
keeping typed transcript/parent/tables; dark largest-text reachable controls. Final
mobile results have no failures, skips or reported runtime warnings, and each
strict three-case verifier passes.

## iPad presentation polish

The first mobile runs passed functionally, but screenshot inspection exposed a
cramped iPad review at accessibility XXXL and one screenshot of the presentation
transition instead of the review. Those images are diagnostic evidence, not clean
visual acceptance. The iOS-owned view now uses native page sizing and a large
sheet. Apple describes [page sizing](https://developer.apple.com/documentation/SwiftUI/PresentationSizing/page)
as suitable for compositional content. Text sizes are not capped or reduced.
Mac keeps its existing native layout.

The mobile visual driver now requires the complete recording button and transcript
frame to be within the presented viewport below its navigation bar; bidirectional
scrolling reveals the intended control. It also checks the post-recording label
and actionable Apply before capturing. Both final mobile runs repeat all three
cases after the layout change. Four final screenshots were inspected: iPad shows
its controls and complete transcript together; phone uses scrollable content with
a complete recording button and transcript at their respective positions. Partial
neighboring content outside the viewport is ordinary scrolling, not missing text.

## Scope and remaining gates

All native recording/refusal events here are synthetic and require reserved Debug
bundle IDs, ui-testing workspace and explicit fixture arguments. The copied host
only renames an existing exact factory guard to its reserved namespace; production
factory behavior is unchanged. App source, copy transformations, signing receipts,
products (including debug dylibs), summaries, logs and synthetic saved tasks are
bound in the retained evidence. Each repo owns its implementation and tests.

The Mac native run passes both cases but reports one QoS warning; its strict
verifier rejects clean runtime acceptance. UUID-matched archived system frames
pass through AppKit Services-menu accessibility inspection and the data-detector
scanner. Unresolved frames remain explicit. This is an observed stack, not a
suppression or a claim that broader Mac runtime warnings are fixed.

A read-only Mac host capability probe reports en-US/en-GB on-device support and
no installed assistant asset for the probed es-ES/da-DK locales. This is not an
isolated-app permission or recognition test. Genuine microphone/speech permission,
audio recognition/accuracy, route/call interruption, audio-session restoration,
background/multiple-window recording and spoken/cross-account native coverage
remain open. A real Mac audio test was requested but has not been approved or
started: no recording permission was requested, no audio played or saved, and no
permission setting changed during this stage.

No real tasks/accounts, hosted service, rollout flag, provider configuration or
release/distribution input changed. Raw Unicode refusal is Core regression proof;
the native flows verify ordinary reviewed capture, not an external raw-source edit
while the modal is open. The wider Px objective and user deferrals remain active.
