# Real local audio delivery and native mobile recovery

Reviewed 2 November 2026. Ordinary client/service gates remain disabled. Nothing is deployed to a hosted project.

## Changes

The first recording upload was blocked by a real Storage API compatibility issue: a missing object returns HTTP 400 with `code: NoSuchKey` and string `statusCode: "404"`. The gateway and fenced cleanup worker now recognize only that precise, bounded wrapper, while preserving the previous direct HTTP 404 contract. Generic/bucket errors, numeric status values, oversized or malformed responses remain failures. A missing published object cannot authorize a replacement upload.

Publication controls now use an explicit borderless button style and minimum 44-point targets. A metadata Check no longer opens the Resume sending confirmation through the containing Form row. The native case explicitly checks that no Resume alert appears.

The isolated native bridge preserves the gateway's checksum and privacy headers. The production client's checksum, byte-integrity, codec and current-access checks remain intact. Test cleanup discovers the current reserved app container after Xcode relocates it, validates configuration contents before removal, and restores the original Simulator state.

## Accepted scope

- Each repository independently passes 52 typechecked gateway/worker tests, including six new wrapper, bounds, quota-preservation and no-resurrection cases.
- The Mac repository passes 13 actual local gateway/PostgreSQL/Storage checks, including first upload, checksum header preservation, exact delivered bytes, author removal, unchanged task data and fenced quota release. This is a service test, not Mac UI acceptance.
- The iOS repository independently passes the complete native case on iPhone and iPad, with 29 service/native assertions per run: a current editor on another person's task captures and saves a private recording; the real gateway commits while its final reply is deliberately lost; cold Check publication reconciles the same frozen intent without another media POST; the ordinary Store sync reads actual SQL/RLS and refreshes conversation state; playback verifies downloaded bytes; actual removal refreshes the empty conversation; and the original private clip, sender receipt and task rows stay intact. Fenced maintenance then removes the provider object and releases quota.

These native flows use the actual app views, Backend, Store, private vault and controllers. Recording/playback hardware drivers are silent synthetic drivers. Storage is the real pinned local Storage API with its real schema and filesystem backend. Auth and native HTTPS/PostgREST routing are controlled adapters to real local SQL; this is not genuine Auth, full production base-schema parity or hosted-provider acceptance. The iOS service preflight is also retained with its earlier narrower direct-handler scope; the accepted native runs supersede it for the current mobile integration.

Current app/runner build, signature, source-matching and report hashes are in verification.json. Reusable build products are kept; failed attempt notes distinguish fixture/oracle corrections from product changes. The 213 Core and 284 controller checks from the preceding client milestone were not rerun: their production models/controller bodies are unchanged here.

## Remaining

Mac UI acceptance, genuine Auth/full-schema/hosted integration, actual capture/playback hardware, broader account/window/background/accessibility/privacy and ambiguous provider-failure recovery; reviewed generation restoration and whole-project recording transfers; and broader legacy migration. The old interrupted iPad file-dialog/cache recheck remains separately open and is not established by this new app-only recording case. All user deferrals remain unchanged.

## Reproduction

Use the owning repository and its dependencies. The runner checks the default storage floor and removes only its own containers, network and configuration. Use fresh report paths.

- Both repos: `deno test --allow-read=TaskfoldTests/Fixtures supabase/functions/audio-comments/handler_test.ts supabase/functions/audio-comment-maintenance/handler_test.ts`.
- Mac service: `node Scripts/Database/test-audio-team-native-provider.mjs service /tmp/taskfold-audio-provider-own.json`.
- iOS mobile: build/sign the exact reserved native host with current owning sources, then `node Scripts/Database/test-audio-team-native-provider.mjs ios /tmp/taskfold-audio-phone-own.json` (or `ipad`). Source/signature/account/cache checks must pass; the test cannot fall back to another workspace. No real credentials or microphone permission are needed.
