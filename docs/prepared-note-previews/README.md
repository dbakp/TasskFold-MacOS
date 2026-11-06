# Prepared note previews

Reviewed 5 November 2026. Both independently owned clients now prepare note block and inline formatting in a cancellable background task. Pinned-note reading and Write/Preview use the same prepared model. A mounted reader reuses it for redraws and the original-text toggle; returning to a newly mounted preview may prepare again. This removes markup parsing from these view bodies without a global/private-content cache or a new persisted format.

A source-bound model is displayed only when its source matches the current note. Canceled workers cannot publish an old result. Existing complete-original fallback for oversized/excessively fragmented notes, Unicode, safe-link policy, typography, code blocks and existing editing/recovery contracts are retained. The pinned reader no longer parses once merely to decide whether to offer the original-text toggle and again to render.

## Verification scope

Each owning Core suite passes 30 selected note/formatting/widget-preview/text-intent tests, including six new preparation cases. These cover block/inline parity, safe links, complete large/fragmented fallback, Unicode/revised content and canceled sync/async preparation. Existing unrelated test compilation warnings remain; no whole-project warning-free claim is made.

Two current signed iPhone Simulator journeys pass with no failures/skips or reported app runtime warnings: the focused edit/preview/history/cold flow and a separate largest-text Preview/Cancel flow. Both screenshots were inspected and retain readable content and reachable controls. The independently built current Mac app also passes strict signature verification; its native runtime is not accepted by this turn. Real-device frame timing, long-note layout/rendering, broader accounts/cloud/accessibility and Mac/iPad runtime remain separate from this background-parsing change. No other unchanged Px matrix is repeated. Neither daily-use app nor prepared Mac21/iPhone33 package is replaced by this source update; a combined update still needs packaging.

The scoped iPhone test checks actual prepared words, revises text through Write/Preview, verifies the original-text toggle against the full text, preserves concurrent task fields and all unrelated canonical data, then uses actual Store Undo/Redo and cold reopening. The first attempt queried a SwiftUI container whose identifier is flattened onto its children; its captured hierarchy proves the content rendered. The next attempt passed the new preview/toggle/save/history checks but exposed retained Simulator legacy view preferences imported at cold startup. The test now establishes its baseline through ordinary cold loading first, retaining the full-table equality assertion. Those earlier attempts are not reported as passing journeys.

Any retained screenshot contains synthetic test content and DEBUG-only fixture controls. It is evidence for the displayed note layout, not a screenshot of an installed normal build or a broad visual/performance audit.

## Storage and ownership

The same marked native build caches and fixed Simulator pool are reused, with heavy platforms serialized and a 20 GiB preflight floor. The end-of-run report records selected compiler caches and Simulator wallpaper scratch cleanup. Core cache sizes are separately measured. Existing packages, real tasks, Keychain items, Docker volumes and unrelated devices/apps remain outside cleanup.

End-of-run cleanup removed 41,283,584 allocated bytes of obsolete failed result bundles after retaining concise failure evidence. Selected native compiler caches and Core caches are each below 768 MiB; approximately 60.1 GiB remains free. The Simulator is shut down and test apps are closed.
