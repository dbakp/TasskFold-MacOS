# Assigned-by saved filters

Both apps now offer **Assigned by** in People and status, with Me, Others, Unknown history and available individual collaborators. Expressions accept `assigned-by:me`, `assigned-by:others`, `assigned-by:unknown`, an exact collaborator name/email or a UUID. `assigned by:me` is an alias. Saved documents keep the version-1 envelope with a strict `assigned_by` predicate; older strict readers reject the unsupported field. The current saved-view database constraint accepts this envelope without another schema change.

The condition means the recorded actor of the **current assignment**, independently of task authorship or the current assignee. It does not claim a complete audit of all earlier assignments. Names resolve through the existing accessible member directory to stable identities; current display names are used for headings. Missing names do not silently retarget the query. An exact historical actor ID can remain meaningful after project departure while the task itself remains readable. Account deletion makes that actor unknown.

## Unknown and excluded conditions

| Condition | Recorded me | Recorded other person | Unattributed historical assignment | Unassigned | Unconfirmed/malformed evidence |
| --- | --- | --- | --- | --- | --- |
| Assigned by me | Match | — | — | — | — |
| Assigned by others | — | Match | — | — | — |
| Unknown history | — | — | Match | — | — |
| Exclude Assigned by me | — | Match | — | Match | — |

Unknown history covers missing legacy records, system actions without an actor, removed actor accounts and recognized recurring copies whose original actor cannot yet be verified. Waiting-for-sync, stale, ambiguous and malformed evidence does not become historical attribution. Unknown does not become another person through negation. Compound conditions retain three-state logic: a true independent OR branch can match; a false independent AND branch rules out the combination. Separate queries retain their own task/completion scopes. A wholly unreadable catalog produces an explicit refresh error with the query/draft retained.

New assignments and all real assignment transitions receive pending cache markers until the server confirms them, including A→B→A and cases without an older metadata row. A new pending assignment therefore cannot masquerade as old unknown history. Same-recipient retries and unrelated edits preserve a confirmed event. Stable child moves preserve their proven event/path, and child deletion/Undo retains its identity semantics. Nested results use the child's own assignment, never its parent's actor.

## Synchronization and local work

The optional history read captures the authenticated session incarnation and discards responses after an account switch, including switching away and back. Missing-table, denied, incomplete-page and transport failures are unavailable, distinct from a successful empty catalog. A fresh task snapshot without a matching history read clears the old catalog instead of reusing potentially stale actor information. Previously synchronized offline task/history snapshots remain readable. Core task synchronization does not depend on this optional feature being available.

Local-only workspaces record real local assignment actions in their account-bound cache, with an explicit local scope. Local evidence is not certified by a cloud reader. Legacy normalization does not invent an actor, and ordinary unassigned captures do not create assignment-history rows. Portable exports exclude both server and local provenance. Generic Store/queue/backend mutation paths still refuse the provenance table; only the server trigger or the explicit local recorder maintains it.

Immutable catalog fingerprints participate in query cache identity. Assignment timestamps are parsed once per catalog with local parsers, rather than per task match. This covers metadata-only actor changes without a task edit. Preview counts, grouped/independent queries, nested results and widget list membership use the same catalog. Widgets receive resolved membership without provenance rows, other members’ actor identifiers, assignment timestamps or filter documents. The existing current-account binding remains. Capture defaults never invent an assignee or write an actor to make a new task match.

## Verified scope and remaining work

See [current evidence](p2-assigned-by-filters-evidence.json) and the earlier [recording foundation](p2-assignment-provenance-evidence.json). Independently owned core suites, genuine authenticated owner/member/outsider HTTP checks, iPhone/iPad native picker/expression/save/relaunch flows and actual saved snapshot/widget publication checks pass. The native tests use an exact DEBUG-only isolated fixture. HTTP checks use disposable accounts, not the user's account; sessions/accounts and local credentials are removed afterward.

Native Mac runtime/layout acceptance, largest-text/dark appearance and VoiceOver, individual collaborator picker interactions, installed widget behavior for these predicates and wider simultaneous native/offline account-change acceptance remain open. Recognized recurring successors deliberately remain unknown pending trusted inheritance; no historical attribution is backfilled or guessed. Distribution, real calendar registrations/provider acceptance, server reminder delivery and broader older-client rollout remain user-deferred. This feature does not close the whole rank or remaining-Px goal.
