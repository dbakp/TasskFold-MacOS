# Note section navigation and lazy reading · 6 November 2026

Both independently owned apps offer Jump to section in pinned-note readers and formatting previews. Lazy blocks and prepared heading captions keep long-note opening bounded. Normal text uses the compact native menu; accessibility text uses a full-height section list. Original text hides contents controls. Saved note representation and ordinary gates are unchanged.

## Routing fix and source binding

The current baseline reproduced an actual largest-text failure: jumping to the last section succeeded, but returning to the first did not bring it into view. Both apps now bind scroll position to explicit lazy-layout targets instead of routing through ScrollViewReader. Source changes reset position from the persistent reader/editor container, including unavailable/returned notes.

Preview preparation, retained heading selection, and editor changed-text guards compare exact UTF-8. Swift canonical Unicode equality can equate two spellings whose actual URL paths differ; these sources must invalidate preparation and retained destinations independently. No new storage format or service behavior is introduced.

The two subsequent toggle failures were test targeting defects. XCTest said the switch was hittable while its tap point was hidden behind the navigation bar (y=68.53). The test now scrolls the actual switch wholly into the visible reader before activating it. The recording was inspected before adapting the selector. See routing-diagnosis.json for the baseline and those failed attempts; they are not passing acceptance.

## Current verification

- Each owner passes 47 selected Core checks, including four new exact-source/Unicode-link tests. These cover formatting, prepared markup, widget text, compact/full previews, pinned-note edits, and retained reads.
- Current signed iPhone Simulator normal-text journey passes first/last reader navigation, both exact original-text transitions, formatting-preview first/last navigation, unchanged all-table snapshots and cold read-only return.
- The separate largest accessibility-text iPhone Simulator journey passes reader first/last navigation, both exact original-text transitions, unchanged tables and cold navigation. It initially realizes three blocks; normal text realizes the count in its receipt, both below the fixture's 70-block threshold. Largest-text editor-preview navigation was not part of this journey.
- Each native journey reports one pass, zero failures/skips and no runtime warnings in the result summary. Synthetic private host only; no real provider/account/data involvement. The normal runner verifies all owning app Swift files and the exact owning test source before and after execution.
- Current iOS app/test and Mac app compile; development signatures verify. The Mac result is build/sign evidence, not interactive acceptance.
- The largest-text destination screenshot was visually inspected: Field guide 12 is visible below the persistent Close/contents toolbar, with text reflowing in the reader.

Mac/iPad interaction, VoiceOver heading announcements, broader source/account transitions, physical scrolling/FPS, and wider workloads remain open. No broad checkpoint promotion follows from this bounded proof. Earlier pre-follow-up receipts remain labeled historical references.

## Daily updates and storage

Normal apps remain Mac14/phone34. Frozen Mac22/phone34 packages and rollback/private backups remain intact; these source changes are not installed. Further iPhone installation is deferred by the user. Mac23 was not packaged or installed.

Completed result bundles, duplicate recordings/frames and over-budget Taskfold compiler caches are retired only after concise results, signatures, source hashes and needed screenshots are preserved. Current-cleanup.json records this run. Real tasks, device/app contents, Keychain, Docker volumes and unrelated output are preserved.
