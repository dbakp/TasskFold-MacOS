# Current move-draft targets and cold recovery

Move drafts now display a current authenticated subtask name in the organizer and global recovery list. The display cache binds to the exact account/origin/workspace/session/access scope, source snapshot, original task generation/project and node incarnation. It is display-only and is never encoded into the saved draft or used to authorize a move. Missing/currently unavailable reads fall back to the generic move label.

Global recovery includes draft identities/revisions in its read request and observes task/snapshot changes. It synchronizes once per opening/action revision, then uses direct snapshot-bound replacement reads so its own synchronization cannot cause a repeated sync loop. Display-only row IDs have separate node/draft/action/archive/disposal namespaces; transport request identities are unchanged.

Each app passes 129 selected hierarchy Core cases: 29 command, 13 read, 87 recovery. Three new label tests cover exact source naming without modifying saved bytes, redacted descriptions, foreign/recreated/missing targets, an Add draft, every live-scope departure, stale snapshots, different draft identity and spoofed private title content. Both owned app/test products build. Final native move-recovery passes on phone (159.387 seconds) and iPad (158.674 seconds), within the original allowance. See verification.json and compressed logs/summaries.

The first phone attempt failed waiting for a destination picker that was below the fold at the largest text size. The corrected test reveals the native picker before interacting; its failure and source phase remain recorded. No allowance is widened.

The revealed-picker phone run reached named cold recovery, retained the selected destination and saved the unsent move, then exceeded the original three-minute allowance during its final relaunch check. The trace showed the organizer had retained its old scroll position below the newly saved draft. The corrected helper searches toward the known top draft section instead of first searching down the list; all assertions and the 180/240-second limits remain. The timed-out run is not counted as acceptance.

Remaining scope includes other placement/index combinations, unavailable/changed destinations, genuine Mac/spoken and wider account/window/background/failure recovery. In particular, confirmation intent must stay bound to its reviewed draft version under a concurrent refresh; coexistence of a frozen draft and a saved action still needs native failure-path acceptance. Full independent-record migration, older-data adoption, team/audio custody and the wider Px goal remain open. Normal gates are unchanged.

## Next recovery checks

- [x] Capture the immutable draft and token when Discard is first tapped. A live row refresh must not change what the existing confirmation authorizes. The isolated native held-alert second-writer check now passes on phone/iPad; see ../child-task-discard-intent/README.md.
- [ ] Exercise a frozen draft, saved action and related receipt/cleanup rows together in the native list; their display namespaces are now distinct, but that failure-path UI matrix is not yet accepted.
- [ ] Complete wider destination/index, unavailable-target, Mac/spoken and lifecycle coverage before normal-use enablement and the full storage migration.

Final captures show the current target name after cold recovery and the preserved destination. At the largest text size the native picker visually ellipsizes the selected destination; its complete value is asserted through accessibility. This pass establishes preservation, not universal large-text/spoken acceptance.
