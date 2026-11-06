# Independent subtask labels

29 October 2026. Both repositories own their implementation. Ordinary child-read
and write flags remain absent/off. Isolated synthetic owner evidence does not
prove hosted service delivery, shared-account lifecycle or genuine Keychain use.

## Behavior

- Expandable Labels controls add/remove labels without replacing other fields.
  Saved order, unknown legacy strings and opaque task metadata remain intact.
  Unsupported containers remain readable through the existing data path and are
  preserved while other fields are edited; label editing is unavailable.
- Personal tasks may choose an exact current catalog entry or enter a name. A
  unique known name resolves to its ID; duplicate names require explicit catalog
  selection. Existing values are never broadly renormalized. Duplicate membership
  and capacity/invalid names fail without changing the draft.
- Shared labels stay portable names. The personal catalog is never used to resolve
  or display shared names. Unknown IDs use a safe saved-label description.
- Per-node checkpoints include added/removed labels plus unfinished input in
  private extras. Only explicitly added labels enter field commands. Saving other
  changes does not retire a checkpoint that still holds unfinished label input.
- Review shows label names or unavailable saved-label descriptions, with explicit
  No labels/Cleared states. Account, source and request guards remain in place.
- Exact Unicode replacement is an authored edit; opening a missing/null/empty label
  field does not silently materialize or normalize it.

## Verification and remaining work

Seven new Core cases cover no-op authored storage, personal name/catalog resolution,
raw-value preservation/removal, shared isolation, unsupported/capacity refusal,
combined planning/label command construction and restored drafts, and canonical
Unicode replacement. Exact final counts/phases/source hashes are in verification.json.

The native fixture uses actual Store factories, encrypted backups/journal and
Backend transport against a synthetic HTTP peer. It checks that Review is sent,
Later remains privately recoverable, one write/request confirms, and both states
survive relaunch. It is not proof of every catalog/shared/remove/role/window path.
Native execution results, screenshots and any failed phases are recorded separately.

Assignment/reminder controls, field-conflict review, general malformed legacy
editing, full Mac layout/speech, actual shared/team/multiwindow/removal lifecycle,
completion/structure/legacy adapters and authoritative child migration remain
open. Previously deferred release/provider/audio/location work stays deferred.
The overall Px goal remains active.

The first native phone phase fails before typing: SwiftUI applied the disclosure's
accessibility identifier to its expanded child field, overriding the field's own
identifier. The captured hierarchy shows the expanded button and Label name field
sharing that identifier. The parent identifier is removed; tests locate the named
disclosure and retain unique field/button identifiers. This phase predates the
final exact-Unicode model update and is not counted as acceptance.

The second native phase reaches Save, and the captured phone hierarchy proves a
durable queued request plus one private draft with Later, but no saved-status
row. Equal label-input binding assignments were advancing the editor revision;
the label binding now ignores exact unchanged text, matching the title/notes
bindings. Local label validation is displayed beside the input rather than as a
server-read failure. This cause is validated only by the subsequent native result,
not inferred from the queued request alone.

Final v3 label Save/review/send/cold cases pass 1/1 on each iPhone/iPad. Review is
the only sent label, Later survives in the private backup extras, and the cold
probe proves one confirmed request/write and one retained private draft. Four
final saved/review images are inspected. V2's largest-text/private-cold case passes
on each device; those images are also inspected. V3 only changes equal label-input
assignments and inline local errors, plus a diagnostic assertion; it does not alter
the largest-text journey's controls. These phases are kept separate.

Final selected Core suites pass 247 cases independently in each repo, plus seven
existing TeamTaskLabelsTests. Full v3 native app/test builds and all four development
signatures pass. No native Mac or spoken label acceptance is claimed.
