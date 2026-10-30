# Independent subtask completion in the apps

Complete, Reopen and receipt-certified Undo have a separate presentation and encrypted journal from field edits. Completion refreshes current task data after confirmation; it never patches a parent tree from a historical receipt or replaces the surrounding editor’s unsent title/notes. Saved subtask actions are discoverable from account settings even after feature gates are disabled.

Recovery distinguishes Send/Retry from **Check and stop if pending**. The latter explicitly confirms an already applied action or permanently closes an unapplied request. A closed request requires current-value review and saves a fresh identity without automatically sending it. Undo uses current cohort/identity validation and its original confirmed receipt. Current-state no-ops and stale Undo explain why another action is unavailable. Forgetting a local record never cancels attempted work or undoes server changes.

Presentations and late callbacks are bound to the account, backend, workspace, session and access scope. Leaving a presentation clears its private read and model. Account removal coordinates journal removal behind the existing removal tombstone; only the reserved synthetic host can use its fixed test encryption key. Ordinary read/write/completion flags remain off. No hosted migration or release configuration is changed.

## Verification

- Each owned repository independently passes **190 selected Core checks**, including 57 completion command/recovery cases and 13 completion draft cases. The seven new presentation-model tests cover offline queue/cold retry, lost-reply applied resolution, explicit stop/fresh saved replacement, late account departure, denied queue admission, actual fresh-read Undo lineage and durable-save failure before any network send. See `core-checks.json` for the exact suite breakdown and filter.
- Initial native Complete/Undo + unsent-draft/cold-state and lost-reply/cold-retry journeys pass on both iPhone and iPad (two cases per device). Retry proves one server write across two requests.
- Screenshot review exposed a keyboard covering the completion feedback. The final controls dismiss focus while checkpointing the draft; one focused final-source follow-up independently passes on each device, including an 8-second keyboard-dismissal assertion and cold saved-state checks. Window-only screenshots were inspected. Final iOS app/test products build and strict team signature/namespace checks pass. See `native-checks.json` for exact phase distinctions.
- Final-source Mac app/test products compile and app/runner strict signatures verify. Runtime acceptance stopped before app launch: the Mac was locked and Xcode reported system authentication already running. No Mac journey is claimed as passed.
- Status notices use the app’s existing high-priority accessibility announcement mechanism; actual listening acceptance is still open.
- Both repositories own their source, tests and `prepare_child_fields_native_test.py --completions` option. The option enables completion only in the reserved isolated app copy.
- Native journeys are being verified with the file-backed synthetic peer. This peer verifies presentation and persistence; the previously recorded PostgreSQL suites remain the authority for database permissions, races, history and atomicity.

## Still open

The exact native phases are recorded in `native-checks.json`. Reopen, stop/review/replacement, wider lifecycle and current-source Mac acceptance remain to be verified before calling this feature accepted. Sustained-use receipt retention is implemented in the [30 October follow-up](../child-task-completion-retention/README.md), with native acceptance still being completed. The evidence above records the earlier UI integration phase. Genuine Keychain/team/account/multiwindow and speech acceptance, structural child commands, legacy/adoption adapters and authoritative migration remain unfinished. The earlier combined-run iPhone tap finding remains open. Prior user deferrals remain unchanged, and the full Px goal remains active.
