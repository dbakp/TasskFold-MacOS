# Preserved child objects in hierarchy views and action routing

The hierarchy index now retains each full source object separately from the contextual display Record. Preserved child objects can contribute titles, exact identity paths and nested containment without collapsing unfamiliar Unicode keys or exact numbers into a String-key dictionary. Ordinary object fields retain their existing behavior, including unambiguous non-ASCII metadata.

A cold Snapshot keeps the original root tree, and the index can be reconstructed with the same references and full source. An indexed row can open its exact independently read child and create a completion command that sends only identity/cohort/action metadata. The display projection is never used as a replacement object. Paths through an opaque object require the independent writer; the old indexed whole-subtree writer refuses those paths before returning a mutation, including ordinary descendants beneath an opaque ancestor.

The total raw-object projection budget is 32 MiB across the index, charged before decoding. This bounds repeated work for nested opaque branches. Refusal leaves the original cache intact; it does not return a partial index or remove a branch.

## Evidence and limits

At the indexed-child-routing milestone, each repository's verification file records 174 focused passing checks and its own then-current app/runner build and signature/source proof. Four added cases cover cold full-source/nested routing, independent completion without full-field replacement, indexed legacy-write refusal with ordinary-format compatibility, and an actual oversized raw object that must be refused unchanged. This is core/build evidence, not native acceptance of opaque indexed rows.

The native history-mapping test also distinguishes observing a disabled Preview control from requiring a tappable control. Its original tablet run was deliberately stopped after the helper repeatedly tried to make the intentionally disabled control tappable. The database's root, records, histories, repair receipts and originals were independently confirmed unchanged. The corrected existing-history iPad run and its separate ordinary-data scope are recorded under `../child-copy-mapping-native/`; it does not certify opaque indexed rows.

Normal-use flags, hosted schema and all user deferrals are unchanged. Full migration/cache integration, broader histories and shared file/discussion custody remain unfinished.
