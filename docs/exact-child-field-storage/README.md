# Exact child-field draft storage

Independent child-field reads now retain the complete source JSON alongside a deliberately limited ASCII-field editor projection. Both read protocols reconstruct their tree from the full source, including distinct Unicode metadata keys that Swift dictionaries equate. Known-field changes never replace the full source with that projection. Unknown numeric/member tokens retain their original representation.

The editor binds its full original to the session at creation. Refreshing a read or submitting newer checkpoint metadata cannot substitute a different original. Private encrypted recovery validates that the saved source projects to the captured original before saving and after cold reopening. Refresh continuation also compares the full source, so changed unfamiliar fields cannot be ignored just because the visible fields match. Existing ordinary editor drafts remain compatible.

## Verification and limits

`verification.json` records source hashes, focused core results and signed app/runner builds for this repository. Tests cover v1/v2 wire fixtures, explicit outgoing field changes, exact Unicode/numeric preservation, malformed and mismatched content refusal, encrypted cold recovery, and the original/newer-read race.

This is core and build evidence, not new native runtime acceptance. Ambiguous full root Records remain refused; the broader editable cache/index migration, complex history mapping and shared file/discussion custody remain unfinished. Normal-use gates stay disabled. No hosted changes, real tasks, new devices or release/signing configuration are involved.

Byte-sensitive tests compare UTF-8 data; ordinary test encoding sorts dictionary keys so ordering does not create false preservation failures.

The final app-model helpers are excluded from the share extension, which uses the preserving codec without the task model. The iOS signed-build check caught this target boundary; it is covered by the final package build rather than inferred from core tests.
