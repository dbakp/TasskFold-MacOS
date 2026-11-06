# Reviewed draft discard intent

Discard now captures the exact immutable draft and its session-bound presentation owner when the initial button is tapped. The real SwiftUI alert uses that captured value for confirmation; a same-ID row update cannot retarget it. Cancellation drops the captured confirmation. The journal format and normal feature gates are unchanged.

Three new Core tests use actual separate journal owners to cover: a newer write followed by a presentation refresh; a newer write before refresh; and session departure. A stale confirmation preserves the updated draft, keeps saved actions and makes no server call. Only a fresh review can remove the updated draft. Each owned app passes 132 focused Core tests (29 command, 13 read, 90 recovery).

The opt-in DEBUG native fault injection operates only in the isolated child-structure fixture and only with its explicit discard-refresh argument. It writes through a second journal owner and refreshes the actual presentation model while the real alert remains open. The native test must observe the updated row before confirming, resume the preserved text, check zero queued/sent actions, then verify the saved draft after a cold return. It does not establish universal multiple-window or background recovery. Both owned app/test products build and verify. The held-alert race and existing Cancel/Resume/Discard regression pass on phone and iPad within the original 180/240-second limits. Exact phase counts, elapsed times and bound sources are in verification.json; original logs/summaries are retained.

Remaining work includes frozen draft/action/receipt coexistence, broader placement/unavailable-target, Mac/spoken/lifecycle checks and the full independent-record migration. The overall Px goal remains open.

The initial Mac compile failed because the presenting-alert message closure requires its data parameter. That closure was corrected before native execution; the failed log is retained and is not counted as a passing build.
