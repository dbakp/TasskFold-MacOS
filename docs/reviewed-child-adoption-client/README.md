# Older-subtask adoption client foundation — 30 October 2026

The client now validates the migration review and constructs a compact request bound to its account, task generation, project/workspace, opaque review fingerprint and expected count. Original content remains a separate ephemeral byte sequence: it is neither converted into a replacement task nor included in the saved request. The preview decodes only identities, titles and nested shape. Unknown numeric precision and distinct Unicode keys in opaque fields survive exactly. Invalid identities, duplicate keys, malformed syntax, inconsistent counters and omitted-source confusion are refused.

The encrypted journal saves queued/attempted/applied/closed decisions under account/origin binding and the existing removal/process-lock guards. Attempts must be saved before sending. Unknown outcomes remain attempted, cold retry uses the original identity, and Stop/status remain available when sending is denied. Settlement validates the exact proof and recovers a file write that finished before reporting an I/O error. Explicit history removal never changes tasks; an uncertain request cannot be silently discarded.

Backend review/decision methods use the existing private, no-cache/no-cookie, redirect-refusal transport with bounded responses and sanitized errors. Adoption byte iteration and review decoding use the generic executor rather than returning to the app actor for each byte. The synthetic large-response route test passes; this is not a production/device performance benchmark.

Each repository owns its source and its actual SQL-derived fixture. Each independently passes 558 selected Core checks, including 18 new adoption cases, and its isolated app/test build with development signatures. The prior 138 SQL checks are unchanged historical evidence, not a rerun. No native app journey, real Keychain or hosted integration is claimed here.

## Still required

Store factories, admission with private drafts/other pending actions, real current-context fencing and account-removal cleanup wiring; native review/diagnostic/recovery controls; original export and explicit malformed-content repair; broader native/VoiceOver/account/window/background/secure-storage/custody/workload acceptance. Normal-use gates remain off and nothing hosted changed. The broader migration checkpoint stays open.
