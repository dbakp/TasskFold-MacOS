# Independent child completion: client proofs, transport and durable retries

This stage connects the immutable saved intent to a typed completion command, strict Complete/Reopen/Undo receipt validation, bounded Backend transport and an encrypted attempted/confirmed journal. Both repositories own their code and release membership. No ordinary feature flag, Store flow, native completion control or hosted schema is enabled here.

## Implemented behavior

- Complete/Reopen commands capture the existing draft’s account/origin-bound body. Durable command identity excludes a past sign-in incarnation so a cold retry can use a newly authorized session for the same account/server. Each active sender is separately bound to the current account, origin, workspace, session and access generation.
- A confirmation must match every literal request/root/project/child identity, action and exact before cohort, with a later safe node revision and a valid advancing completion epoch/version. Unknown keys, duplicate JSON keys, changed heading presence, malformed times, wrong tokens and altered before/after values are refused. Completion times use the bounded server format; a final safe token can be confirmed but cannot authorize a further transition.
- Undo captures a fresh child read and the original validated command/receipt, using a new request ID. It preserves the original historical time and flag presence while requiring the current cohort to equal the confirmed result. It cannot Undo another Undo or change original target identity. The original proof is local validation material and is never sent as extra RPC fields.
- The journal stores at most 64 immutable entries without coalescing. It writes attempted state before network I/O and confirmed proof before returning success, blocks later unsettled actions for the same target, refuses receipt replacement and preserves ambiguous outcomes after lost replies or failed proof writes.
- An Undo needs its original durable confirmed entry. The journal refuses orphaned, unconfirmed or duplicate Undo references and will not forget a parent while an Undo depends on it. Attempted entries cannot be discarded or silently replaced; completion-specific server terminal resolution remains required.
- Account/origin-bound AEAD files use the existing safe atomic file layer, shared process/removal locks, cancellation leases and removal tombstones. Corrupt archives, wrong keys, wrong scope and symlinks cannot overwrite unrelated files. Store registration/cleanup and genuine Keychain/lifecycle acceptance remain separate work.
- Backend posts only the exact reviewed server body, binds both ends to the authenticated session/server, refuses redirects through the existing delegate, uses no cookies/cache and caps response headers/streamed bytes at 16 KiB. Failure messages retain the request and omit server details. Late success and failure after a live scope change are suppressed. The sender never edits a task cache optimistically.

## Evidence

Each repository passes **237 selected host Core tests**, including **35 new completion-command tests** and the existing draft, field command, child read, checklist, completion-revision and account transport regressions. Each also reruns **98 isolated database checks** without changing the canonical SQL, retaining actual Complete and Undo request/response pairs from the real functions in its own test fixture. The client Undo factory produces the actual database request and accepts the actual returned receipt. These checks complement the simulated service/HTTP interruption and encrypted-disk tests; they are not hosted or native app acceptance.

`verification.json` records exact source and fixture hashes, suite counts, project membership and cleanup. The server report was refreshed only to retain Undo proof metadata; its SQL hash and archived 95-case field regression remain unchanged. Existing unrelated package concurrency warnings remain; the new URL protocol test does not add an unavailable Sendable conformance.

## Remaining before the complete feature

- Completion-specific terminal outcome lookup/closure and explicit replacement of uncertain or obsolete attempted requests. Keeping an attempted request is not cancellation of possible server work.
- Store registration, access/refresh/removal lifecycle and premium native completion feedback, review and Undo controls.
- Current app builds, actual native and spoken accessibility acceptance, and genuine account/Keychain/window/team lifecycle.
- Structural/legacy/adoption adapters and authoritative independent-child migration before ordinary rollout. The known combined-run iPhone interaction finding and all prior user deferrals remain open.
