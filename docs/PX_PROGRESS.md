# Maintained Px dashboard

Open **PX_PROGRESS.html** in a browser. The same reviewed snapshot is rendered as an inline conversation artifact. Each app repository owns all files; neither reads its sibling at build or render time.

## Sources and meaning

`px-progress.json` is the curated snapshot. It reconciles the current P0 summary/audit, P1 completion audit, P2 checklist/plan, account-removal requirements and latest independent-subtask evidence. It does not count the repeated historical appendices. Every section lists its evidence files.

- **Verified**: the recorded acceptance scope passed; no universal or release-ready claim.
- **Built · checks left**: implementation exists, but acceptance, integration or enablement remains.
- **To build**: implementation or design decisions remain.
- **Deferred**: explicitly paused or waiting for the user's configuration/device session.

Bars count equally sized tracked checkpoints, not effort. No overall percentage or completion date is estimated. P1's agreed batch is accepted; genuine provider setup and the separate advanced P2 work remain visible. Normal-use gates are not cleared by a green checkpoint.

## Update with each milestone

1. Read the changed evidence and revise the relevant snapshot rows, current focus, next steps and review date. Keep completed rows rather than replacing history with a new denominator.
2. Run `python3 Scripts/render_px_progress.py --refresh-sources`. This records the reviewed evidence-file hashes and regenerates the standalone page and inline fragment.
3. Run `python3 Scripts/render_px_progress.py --check`. This is read-only and fails for changed evidence hashes or stale generated output.
4. Commit/push each affected repo's own files. If showing the artifact again, use `--preview-output <durable-conversation-path.html>` to refresh its inline copy.

The generator uses only Python's standard library. The standalone page has no external assets, network requests or app-data access. Native disclosure controls reveal the done/remaining lists; expansion state is presentation-only. No checkboxes can change the factual progress.
