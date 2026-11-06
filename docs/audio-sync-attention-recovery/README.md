# Main-screen recovery and clear retry guidance

Reviewed 3 November 2026. Follows [queued Settings recovery](../audio-queued-settings-recovery/README.md).

## Product changes

A lost committed reply previously fell through the shared task RPC error mapping to a generic edit-review message. The main screen could ask for review when retrying the saved request was enough.

Both Backend implementations now distinguish an unstructured transient response to a durable shared-task POST from an explicit service decision. The bounded five-path whitelist covers single editing/lifecycle, selections and single/group completion. HTTP 408, 429 or 5xx without a nonempty service code produces a neutral unconfirmed-write error. SyncStatus explains that work is saved on this device and can be synced again. This does not claim the server applied or rejected it. Explicit service codes retain their existing conflict, access, session, closure and other handling. Read/metadata failures and malformed successful receipts do not become this error. Streaming response bounds and session/generation guards remain ahead of classification; no raw provider detail is surfaced by the new error.

No automatic replacement or fallback write is added. The original queue remains authoritative. The iPhone main-screen action now has an accent-coloured retry icon and a full 44-point label hit rectangle; it is source-guarded disabled while Store is syncing. Stable notice/action identifiers support the native check. No settings identifiers or rollout switches change.

## Verification

Each owning repository independently passes 211 focused Core tests, including three new cases. Representative batch sends cover six transient statuses, JSON/HTML error bodies, one unchanged request per call, and a later successful replay. Explicit refusals keep their existing handling without private message leakage. A metadata read failure and malformed success remain separate.

The accepted iPhone Simulator case passes 68 actual service/native checks and one UI test without skips. It uses production RootView/Today, the sync-attention review control, recovery view, Store, queue/cache and manual Retry action against actual local PostgreSQL/RLS, production gateway and pinned Storage. Auth, HTTP routing, initial data/media and startup bootstrap remain synthetic. This does not establish genuine sign-in/full-schema/hosted bootstrap or Mac/iPad runtime.

Three tasks in one project include an expired/purged recording, one retained recording and one empty member. Newer title/notes and two-task priorities are queued behind the blocked restore. Open recovery directly from Today, choose Later without changing the queue, reopen with fresh consent and recover. After its committed reply is lost, the main notice shows the exact safe retry copy. Tap the upper padding of the 44-point Retry target: the same restore replays, the single edit applies, and the planning reply is lost. The planning request and all newer previews stay exact. Retry again acknowledges the same planning request, clears the queue and removes the notice/action without another task review. A cold return through Settings preserves every final field.

Exact SQL receipts prove no duplicate edit effects. Available recording identity/download bytes remain exact, expired audio stays purged, and no extra media upload occurs. Existing private paths/bytes are compared where present; no new private capture is inferred. Owned configuration/services close and the Simulator returns to its initial state. The final main-screen screenshots were visually inspected at the tested dark appearance/text size; the full button frame is reachable and at least 44 points high. The busy-state guard is inspected in source, not a separate timed response-hold test.

## Attempt qualifications

Native v1 stopped before the main review because the test queried a collection view; Today uses the existing datedTasksScroll scroll view. The test now resolves that real container, and its reveal helper supports either an existing scroll view or collection view. Native v2 passes all 68 functional checks. Screenshot review then found the Retry action too muted. Native v3 adds the accent/icon/full hit rectangle, asserts its height and activates its upper padding, then repeats all 68 checks. The final evidence uses v3; earlier partial/functional attempts retain their own scope. Current app/runner builds and strict signatures pass independently in both repos.

## Remaining

Finish Mac/iPad runtime, other recovery outcomes through each ordinary entry, normal authentication/bootstrap, broader queued completion/move/recipient histories, account/access/window/background/privacy, spoken accessibility and largest text. Explicit coded server pauses and other status messages retain their earlier copy and need broader review. Large queues, legacy/sparse migration, mixed media/discussion expiry, whole-project transfers and genuine Auth/full-schema/hosted integration remain. No production migration, deployment, release-signing acceptance or normal-use enablement. Curated totals remain 74 checkpoints and 35 substeps.

After retaining reports/logs, concise attempt evidence and exported images, the two superseded terminal result bundles were removed (19,312,640 allocated bytes). The accepted v3 result and current hosts/products/devices are retained.
