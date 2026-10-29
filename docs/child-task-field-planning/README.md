# Independent subtask planning controls

29 October 2026. Both repositories independently own this implementation. Ordinary
child record flags remain absent/off; these controls are accepted only in reserved
isolated synthetic-owner hosts. No hosted SQL, genuine credentials or real tasks
were changed. This is another field-editor stage, not the complete child migration.

## Implemented

- Expandable Plan controls for planned date/time, local or fixed device/inherited
  time zone, independent deadline and 1–10,080 minute estimates. Common estimate
  presets supplement the one-minute stepper. Heading nodes do not show Plan.
- A value draft retains the entire authored child, emits only changed planning
  fields and keeps unedited opaque metadata/reminders/legacy scheduling intact.
  Explicit schedule changes use existing TaskPlanning resolution and update the
  fixed instant; removing the planned date clears its clock/zone/instant while
  retaining deadline, estimate and other fields.
- No-op and unrelated changes preserve an existing exact DST fold/instant. A
  nonexistent wall minute resolves forward and displays the resolved minute.
  Invalid inputs fail atomically. Unknown legacy combinations may still require
  explicit replacement; this stage does not claim general legacy repair UI.
- Planning values join existing per-node private checkpoints, account-bound Save,
  separate Review/Send, durable receipt/retry and cold refresh paths. A saved
  planning draft can be read back from the actual encrypted backup format.
- Review uses human field names, date formatting, minute units and an exact
  fixed instant marked UTC. The request body itself is unchanged by formatting.
- On Mac, the expanded editor uses a scrolling grouped Form: the original plain
  layout clipped the top when every control was open.

## Evidence and limits

Eleven new planning cases cover exact no-op/opaque preservation, fixed rescheduling,
local/all-day transitions, clear-plan scope, unrelated legacy edits, invalid and
boundary values, date-before-time admission, retained fold, encrypted private
checkpoint readback, command construction and a DST gap. The first gap model
failed one assertion (02:30 displayed for a resolved 03:00); final selected Core
suites pass 240 cases independently in each repository.

Native phases and exact source/build/screenshot hashes are recorded in
verification.json. An initial iPhone estimate case tapped the labeled switch row
rather than its child thumb; the exported hierarchy proved the value stayed 0
and Save remained disabled. The corrected test targets the actual switch and
asserts its value and enabled Save before proceeding. Its next run passes. The
original largest-text/private-cold case passes with the new Plan row as well.

Direct Mac computer use exercises all six planning fields: date, time, fixed
Copenhagen zone/instant, deadline and estimate; the saved request explicitly shows
those six fields and sending confirms one synthetic write/request and 30 minutes.
The scrolling expanded form was inspected. Escape during an earlier preset
check preserved a private draft; that was not counted as a Save. Final human
review wording and cold Mac observation remain open after the Mac relocked.
Terminal container readback was denied by macOS and was not bypassed; the Mac
observation is UI/probe evidence, not independent encrypted-container parsing.

Spoken/real-device planning, actual service delivery, team/assigned/label/reminder
controls, field conflict review, wider malformed legacy editing, multiwindow
lifecycle, genuine Keychain/removal acceptance, completion/structural/legacy
adapters and authoritative migration remain open. Existing deferred release,
older-client rollout, remote delivery and external-provider/audio/location checks
stay deferred. The overall Px goal remains active.

## Final mobile visibility acceptance

Final product source is shared by v15/v16; v16 changes only the native test reveal
helper. iPad v15 passes both estimate Save/review/Send/cold receipt and largest-text
private draft preservation. iPhone v15 passes estimate Save/review/Send/cold receipt;
iPhone v16 passes largest-text private draft preservation. The cold private readback
uses normal text size. These are synthetic owner flows, not hosted-service or spoken
acceptance. Final kept saved/review screenshots are included alongside their hashes.

Earlier strict viewport assertions found real saved-feedback clipping. SwiftUI
Form coordinates crossed hosting boundaries; later, its last lazy status row did
not exist yet. The final iOS anchor first realizes that row in the native Form,
then proves the entire cell visible before accessibility focus. A scoped bounded
request cancels on newer editing/departure. Mac uses grouped scrolling Form.
Diagnostic JSON is synthetic and came from temporary host-only instrumentation;
no diagnostic instrumentation ships in canonical app source.

Earlier phone parent-switch taps and keyboard-intersecting scroll gestures, a
navbar hittability exception, and oversized synthetic diagnostic labels were test
harness failures. The final helper uses the visible Form area above the keyboard;
only read-only oversized fixture diagnostics may be partly visible. Saved feedback
and actionable controls still require full viewport containment. Phase summaries
and logs retain failed runs rather than combining them into a clean suite claim.

Both development app/runner signature checks pass. The final Mac launch attempt
was closed after computer use again reported locked. Owned Simulators are shut
down; their original VoiceOver states are restored (phone on, tablet off). No
microphone or real account data was used. Obsolete generated builds and archived
result bundles were pruned; reusable hosts/build/Core caches remain available.
