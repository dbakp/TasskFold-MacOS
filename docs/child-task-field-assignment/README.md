# Independent subtask assignment

29 October 2026. Each repository owns its app code, test sources and evidence.
Normal child read/write flags remain absent/off. The saved root JSON remains
authoritative; the full independent child migration and Px goal are unfinished.

## Implemented

- Assignment joins title/notes/priority/planning/labels in per-node private drafts,
  field-only commands and separate Save/review/Send. Opening an absent, null or
  unsupported legacy assignment never rewrites it. Explicit identity/clear changes
  preserve every unrelated field and survive restoration from a private draft.
- Shared projects reuse TeamTaskAssigneePicker and its existing strict, transient,
  project-scoped recipient catalog, live eligibility recheck and current-role/token
  fences. Its optional child-editor footer describes private intent accurately;
  ordinary task editors retain their existing footer/behavior.
- Personal projects use the existing accepted member directory, with searchable
  choices. Every other-person tap refreshes that same captured directory. Removed
  people and invalid/failed directory replies cannot apply; confirmed scope loss
  removes names. A connectivity-only failure may retain an already reviewed
  in-memory choice as private intent. A new/unreviewed identity cannot be invented.
- You and Unassigned require no directory, including while a refresh is pending.
  The callback binds the original account/origin/workspace, node and editor
  revision; newer edits or departure cannot assign a different draft.
- Review resolves current names in the original account/project and explicitly
  shows an unavailable-name fallback. Name lookups reuse the existing project-directory cache; no display names are added to durable field commands, and
  the service remains authoritative over assignments and current permissions.

## Verification and scope

Ten new focused Core cases cover authored no-op storage, identity/clear/invalid
edits, restored intent and unrelated fields, no-I/O self/clear, removed recipients,
late directory replies/selections, self choice during an in-flight refresh, reviewed-only offline choice and invalid-directory clearing.
Each independent repository passes 226 selected cases: 64 child commands, 21 child
reads, 55 account transport, 69 backup and 17 existing team-recipient checks. This
filter differs from the preceding planning/label filters; it is not a decreasing
full-suite count. Exact native phases, source hashes, builds and screenshots are
recorded in verification.json.

The reserved native host uses actual Store factories, encrypted private files,
Backend and native editor/recovery controls against a synthetic HTTP peer. Its
personal Inbox case assigns You, saves/reviews/sends, checks the exact identity
after cold launch, then clears it and repeats exact cold checks. It verifies two
requests/writes/confirmed receipts and preserves the task title. The separate
largest-text/private-cold case checks the longer form and complete saved feedback.
Neither is proof of genuine shared/provider delivery or assignment side effects.

Native project-member/shared selection, current-name lookup races, Mac runtime and
speech, genuine Keychain/account-removal, actual role/multiwindow/hosted lifecycle,
assignment provenance/notifications, reminder controls, conflict review and general
legacy repair remain open. Completion/structure/legacy adapters and authoritative
migration remain open. Previously deferred release/old-client/remote delivery,
OAuth/inbound provider, genuine audio and physical location work stay deferred.

Final native suites pass 2/2 on each iPhone/iPad: self/clear with exact cold field
checks, and largest-text private draft preservation. Six self/clear/largest saved
feedback screenshots are inspected; the full status is inside the viewport. Cold
private readback uses normal text size. Both development app/test builds and all
four strict deep signature checks pass. Platform debugger/AX-loader diagnostics
are retained in logs; no claim of a warning-free platform runtime is made. No
Mac runtime or spoken acceptance is claimed.
