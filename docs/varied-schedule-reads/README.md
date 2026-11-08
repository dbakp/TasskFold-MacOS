# Varied schedules and first dated reads

Each operation now owns up to two lazily configured ISO instant parsers. The existing wall-minute validation, saved-fold checks and fallback remain shared with the ordinary fresh-parser resolver. Repeated schedules still reuse their planned day; different saved instants reuse only parser configuration. No parser is global, persisted, retained with task rows or shared with another worker/account. Empty/floating schedules avoid parser creation.

Today/Upcoming query misses, grouping and drag targeting use the same operation-local reader. The iOS overdue count and planning queue also use one reader per evaluation; the Mac overdue pass resolves each row once. Existing source validation, current-row ordering, task-kind/completion policy, synchronous durable saving and Undo remain unchanged.

Ordinary dated sections now retain their current read across a minute tick, with day, zone, query, selected date, calendar, snapshot, access, session, workspace, origin and readability still fenced. Explicit clock-window filters keep minute-sensitive keys. Saved-filter rules are resolved inside Store, so their cache keys conservatively retain the minute even when the incoming query has no AST.

The fixed iPad workload has 2,004 tasks: 504 dated rows, including 500 distinct saved schedules, and a 2.88 MB retained reference. Real before/after warm/cold drags verify the committed dates, current destination geometry, all 2,003 unrelated tasks, the pending queue and cold reopening. The additional native planning check opens the actual three-task current queue, then cancels without changing work. A separate actual Store check exercises minute reuse, observation, source/date/title changes, project-only archiving, unreadable redaction, clock/day refresh and exact durable restoration.

The earlier parser-only native run had one slow warm geometry observation; its profile remains in intermediate-after.json rather than being discarded. Final timing and acceptance are recorded separately in verification.json. Measured read/preparation/commit/geometry stages are Debug Simulator observations, not physical frame rates or whole-app latency guarantees. Wider first-use, Mac, phone, accessibility/account and physical smoothness checks remain open.

Normal installed Mac 48 and phone installation are unchanged; the latter remains deferred. No hosted schema, advanced feature gate, real workspace, Keychain item or shared Docker volume is changed. Both repos own their source and verification inputs independently.
