# Transfer action layout follow-up — 30 October 2026

The largest-text iPhone confirmation previously clipped the Undo label. Both independently owned views now give its text room to wrap, with a full-width action and a decorative baseline-aligned icon. The native test reveals the action, checks it is reachable, and records a screenshot before the cold-launch Undo journey.

Both isolated app/test builds and strict development signatures passed. iOS owns two passing iPhone Simulator journeys and two iPad journeys: largest-text nested move/cold Undo, and uncertain reply/cold retry without duplicate writes. Before/after phone and current iPad screenshots are retained for visual inspection. These are synthetic same-Inbox journeys; Mac runtime, speech, shared-account lifecycle and real Keychain/hosted acceptance remain open.

No Core or SQL implementation changed, so the preceding 540/77 checks were not rerun. Normal-use gates remain off. This closes a layout defect, not the broader migration or release checkpoint.
