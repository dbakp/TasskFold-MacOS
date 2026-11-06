# Audio conversation pagination — 28 October 2026

The gated live conversation now loads beyond its first 20 comments. Both repos independently own native, gateway, migration and test sources. No hosted migration/flag was deployed or enabled.

## Implemented

- A service-only page RPC checks the live actor/session, feature/bucket state and exact task/generation/project scope on every request. It uses the existing published-only task/generation/time/ID index and the coordinator's lock order. Cursors are positions, never authorization; anon/authenticated roles cannot execute the wrapper.
- Keyset pages return up to 20 records plus one lookahead, ordered by publication time and comment ID. The next cursor retains the exact PostgreSQL microsecond timestamp string. Removing a cursor row does not prevent continuing; there is no offset skip. Page requests do not freeze a whole conversation snapshot; Refresh obtains its current beginning.
- The gateway's new page action shares the existing metadata admission/rate budget, checks exact page/cursor/target shapes, strips custody paths and validates the returned next cursor against the final item. Existing list clients retain their previous response contract. There is no silent fallback from paging to a truncated old list.
- Native cursors bind account and exact target, preserve timestamp strings and reject mismatched/replayed next positions. The existing authenticated, bounded, redirect-refusing transport now supports the page route. The controller appends pages without duplicate comment identities, preserves loaded rows/cursor on a failed Load more, stops at the terminal page, and clears rows/cursors on close/inactivity/context departure.
- The grouped conversation has explicit Load more recordings and Refresh. It retains the existing separately gated personal-root admission, verified on-demand playback and explicit removal controls. Native visual/runtime/accessibility acceptance remains open.
- The task's retained-recording count quota increases from 20 to 100 so pagination is useful for supported publication histories. The independent 100-per-author, 250 MB author and 50 MB task byte quotas remain. Retired-but-unpurged recordings still count. A forward migration redefines only the existing ledger's task-count limit and introduces the private page function/service-only wrapper; it does not expose tables or grant client custody access.

## Verified independently per repo

- **180 audio Core tests**: exact microsecond cursor wire bytes, account/target binding, invalid/short/replayed next refusal and fixed native route, alongside existing recording/publication/recovery cases.
- **271 actual app-controller checks**: 45 ordered records across three pages, failed-page retry with preserved rows/position, terminal stop and cursor clearing, alongside existing privacy/media/lifecycle checks.
- **20 Deno gateway tests**: existing publish/read/remove boundaries plus page shape, custody stripping and invalid/duplicate next/item refusal.
- **25 actual PostgreSQL/gateway pagination checks**: 45 synthetic ledger records, identical timestamps, adjacent microseconds, deleted cursor row, replay, malformed/foreign/session-revoked cursors, inaccessible client RPC, actual HTTP pages, successful reservation beyond 20 and refusal at 100. The task quota test uses another author for padding so the author quota cannot hide a missing task cap. Advisors ran before and after with no added findings.
- **24 native/gateway/PostgreSQL checks**: the actual native reader now uses the page route for its live list, with verified download, lost removal reply/retry, post-removal refusal and unchanged private confirmation. This suite uses controlled Auth/Storage and synthetic media, not a hosted provider.

Pagination ordering/quota tests seed metadata directly into an owned database; they do not claim 45 real provider uploads. Every owned database container is removed. Full unsigned app builds target Mac arm64 and iOS Simulator arm64/x86_64; built draft/publishing flags remain absent/off. No app was launched or real microphone/dictation/speaker/system-permission check requested. Existing unrelated SDK/concurrency warnings remain; compilation is not native UI, signing or provider acceptance.

[Builds](builds.json) · [Source bindings](source-bindings.json) · [iOS Core](core-ios.txt) · [Mac Core](core-mac.txt) · [iOS controller](controller-ios.json) · [Mac controller](controller-mac.json) · [iOS gateway](unit-ios.txt) · [Mac gateway](unit-mac.txt) · [iOS database](database-ios.json) · [Mac database](database-mac.json) · [iOS native integration](native-ios.json) · [Mac native integration](native-mac.json) · [iOS build](app-ios.log.gz) · [Mac build](app-mac.log.gz).

Reproduce from either repo using an owned scratch directory:

```sh
swift test --scratch-path /tmp/taskfold-audio-pages-core --jobs 2 --filter AudioComment
python3 Scripts/test_audio_comment_capture.py --scratch /tmp/taskfold-audio-pages-core --output /tmp/audio-pages-controller.json
deno test --allow-read supabase/functions/audio-comments/handler_test.ts
node Scripts/Database/test-audio-pages.mjs /tmp/audio-pages-db.json
node Scripts/Database/test-audio-native-publication.mjs /tmp/taskfold-audio-pages-core /tmp/audio-pages-native.json --retain-audio
```

The forward migration was created with `supabase migration new audio_comment_keyset_pages`, after the draft page function passed actual PostgreSQL/advisor checks. Its final source, quota change and service grants are then applied and checked by each independent database fixture. No hosted schema is modified.

## Next gates

Shared/read-only Store admission and shared text-conversation integration; native runtime/visual/largest-text/keyboard/spoken acceptance; legacy/unknown-upload/history recovery; hosted provider/custody/removal acceptance and user-deferred genuine audio checks. Ordinary audio and the overall Px objective remain open.

The preceding [live preview checkpoint](../audio-live-preview/README.md) records its original 20-comment cap. This checkpoint implements paging and the higher retained task count; it does not supersede that checkpoint's other acceptance limits.

Follow-up: [shared read-only audio](../audio-shared-read/README.md) adds separately authorized project viewing and shared-conversation entry points. Team writes and native/provider acceptance remain open.
