# Mac note formatting — functional acceptance

Four actual signed native cases pass with whole-table preservation checks. See
validation.json and mac-summary.json for exact behavior. The production inspector,
formatter, selection/preview, Save/Undo and cold-return paths are exercised.
Only DEBUG controls for the reserved local fixture and UI tests are added.
The one-shot out-of-space error is deliberately injected, not real disk failure.
The concurrent-note case uses a real local Store edit, not a live remote client.

Four window-only captures are visually inspected: readable bold preview; original
notes after Cancel; complete save warning with retained draft/Copy/Apply; and
newer parent notes alongside the retained stale draft and explanatory warning.
The “Other edit” control appears only under the reserved DEBUG test flags.

Strict runtime acceptance remains OPEN. Four thread priority-inversion warnings
are recorded around opening the inspector. No call stack proves their origin,
and they are not dismissed as framework-only. The strict verifier rejects them;
the separately recorded functional verifier explicitly permits warnings while
checking four passes and zero failures/skips. Broader accessibility, layout,
workspace/access and genuine cloud concurrency are not closed by these cases.

The first attempt used an exact title lookup that missed the clipped accessibility
value. The second selected a Touch Bar duplicate for discard and could not find
a DEBUG toolbar control omitted by the Mac sheet. Stable task identifiers, visible
window buttons and an inline scoped fixture control repair the harness. Earlier
failed summaries/logs remain evidence; final passes are the only accepted cases.

Each repo passes 15 focused Core note cases; there is no new full-Core or iOS
native acceptance claim. Each repo retains its own evidence and plan; Mac owns
all new Mac test code. No sibling build dependency, server or real-data change.

The account-removal profile gate remains deferred: read-only inspection finds
only two iOS profiles and no Mac private-Keychain profile. No signing changes
were made. See profile-gate.json. The full ranked objective remains active.

The final accepted round strengthens Cancel, failed Apply, stale Apply and stale
cold return to compare the complete persisted snapshot, including queues and
widget metadata. All four cases pass again; the four priority warnings remain.
The earlier table-only passing round is retained separately and superseded.

## 27 October follow-up: Print focus and command routing

The original production Print implementation fails the new repeated-command /
empty-Inbox navigation regression while its existing long-PDF check passes.
A persistent per-window target now keeps the focused scene value stable; the
visible list registers a live action and enabled state. Owner checks prevent a
late disappearing list from removing the incoming list's action. Calendar removes
the list action and returning to a list restores it. No document is captured
until invocation. The existing typography, preview, rendering and save flow remain.

Three distinct print checks pass strict verification with no runtime warnings.
Four note cases individually pass with full-snapshot preservation against the
same production binary. Their five-case suite is retained as FAILED because the
Calendar harness used a clipped task title; it is not presented as a passing
suite. The corrected standalone Calendar check uses the View menu and stable
child identity and passes strictly. Test-only additions do not change the app
binary. See ../mac-print-focus/ for summaries, exact inputs and rejected attempts.
No new Core or iOS native result is claimed.

The app's FocusedValue-update warning is absent in all final diagnostic scopes.
Separately, all four original priority-warning stacks now resolve through
NSConditionLock, AppKit Services-menu data-detector initialization and AX hierarchy
inspection. Window-only queries did not remove that wait and were reverted.
These are diagnostic attribution and a distinct app focus fix, not proof that the
priority wait is fixed: strict note-runtime acceptance stays OPEN. VoiceOver,
large text, broader account/access, real concurrency and new pinned-note variants
remain outside this follow-up. All data was synthetic and local; rollout and
user-deferred dependencies are unchanged.
