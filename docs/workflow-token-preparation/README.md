# Widget token preparation scale

A sample of the previous committed Mac full-workflow save showed repeated
ISO8601 formatter construction/parsing inside WidgetCompletion.prepare. The
sample is diagnostic evidence, not a precise CPU percentage or a latency
benchmark: its own timing includes profiler overhead. Comparative measurements
use the preceding committed stage's unprofiled native results.

Each prepare pass now owns two lazy formatters, a memo of canonical timestamps,
and one sorted-key JSON encoder. Empty instants avoid parsing. No formatter or
memo is shared across calls, workers or accounts. Unknown dates retain their
original spelling. Memo keys use exact UTF-8 bytes: canonically equivalent Swift
Strings can have distinct raw encodings and therefore distinct old signatures.
The initial String-key prototype failed that new regression case before it was
committed; the retained red result demonstrates the failure. The accepted code
uses byte keys and passes the expanded legacy-signature corpus.

The signature field order, digest, version/type/generation binding, token and
receipt formats, child-signature path and failure fallback stay unchanged. No
migration or token reset is required. A failed encode cannot contaminate the
following record. The memo dies when preparation returns.

Core checks compare all 5,000 old tokens/signatures over mixed timestamp formats,
including invalid Unicode spellings; separately check 5,000 distinct instants;
preserve tokens on equivalent date spelling and rotate on an actual new instant;
verify heading roots/productive children; and exercise simultaneous independent
saves. Existing widget, hierarchy and productive-work cases remain covered.
All seven new compatibility cases are rerun against the final source.

Acceptance targets three unchanged native cases on each Mac/iPhone/iPad host: actual Store saving
of 1,000 and 5,000 tasks with all commands, one Undo/revision and all widget lists;
then real intent completion, retry, Undo and cold return. The cases use only
isolated synthetic data and do not claim production-screen rendering, release
latency or genuine hosted/paired delivery. Final summaries, source/binary bindings
and metrics are retained here. The earlier String-key prototype's native passes
are intermediate evidence, superseded by the byte-key runs.

The remaining save pause and background widget readiness remain open, alongside
local-history scaling, full production responsiveness and the wider ranked Px
backlog. Normal rollout flags, release/provider setup, remote reminders, older
client exposure and physical geofence deferrals are unchanged. No real workspace
or hosted schema/service was changed. One current native cache per platform is
retained for the next active-goal work; obsolete owned test artifacts are pruned.

Final status: all three cases pass on each Mac/iPhone/iPad host, with no runtime
warnings (nine platform/case pairs). After the user's explicit automation approval,
the same signed final Mac binary completed the requested cases. Prior initialization
failures remain historical evidence; the earlier String-key prototype is superseded.
See mac-summary.json, mac-final-bindings.json and mac-automation-initialization.json.
The broader goal remains active.

| Final byte-key implementation | 1,000-task save return | Widget ready | 5,000-task save return | Widget ready |
| --- | ---: | ---: | ---: | ---: |
| iPhone Simulator | 0.53s | 1.38s | 2.48s | 14.44s |
| iPad Simulator | 0.52s | 1.38s | 2.47s | 14.40s |
| Mac | 0.45s | 1.28s | 2.23s | 16.22s |

The previous committed stage measured 6.82/6.96s full save return on phone/tablet.
The current roughly 2.5s pause remains too long. These are Debug observations,
with remote delivery paused in the exact isolated fixture, not latency guarantees.
