# Current-action review feedback — 30 October 2026

The subtask review sheet now shows feedback only from an action started in that presentation. Opening it after an earlier confirmation no longer repeats that confirmation. Late feedback is fenced by the captured account/workspace scope and presentation identity. The parent status pauses its explicit announcement while review covers it; a failed reviewed action has its own status, and successful Save/Send/Undo returns to recovery.

Disabled Save/Send/Undo labels now use a muted colour. Their actual disabled state still comes from the existing admission and no-op checks. The iPhone and iPad window-only screenshots show the completed-state explanation, muted Save action, and no stale confirmation. The native test explicitly checks that the child status is absent on a new no-op review.

## Verification

One focused native test passes on each iPhone and iPad: stop an offline action, cold-return, review current values, save a fresh replacement without sending, explicitly send from its review, reject a redundant completion and cold-read the saved result. Exact times and source hashes are in `checks.json`. Both app/test products build and their strict signatures verify. These are isolated synthetic service journeys; no hosted acceptance is inferred.

Core and database code are unchanged by this UI patch; prior suites are not counted as new runs. Mac runtime remains unverified because computer use reconfirmed the Mac locked. Spoken announcements, largest-text review, broader account/team/multiwindow lifecycle, structural commands, legacy/adoption and authoritative migration remain open. Normal feature flags remain off and prior user deferrals remain.
