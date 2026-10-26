# Reviewed conversion of older Todoist headings

26 October 2026. Both independently owned apps offer **Review imported heading**
in their existing gated personal heading editor. Normal authoring remains off;
cloud/shared type adapters and rollout are still separate work. This advances the
older literal-copy review item without changing Todoist or retry semantics.

A candidate must be an ordinary, open Taskfold row with recognized Todoist source
metadata whose original content has a nonempty leading `* ` heading marker.
Current Taskfold titles alone never imply a heading. Malformed states, completed
rows, unknown task kinds, and missing/other-provider evidence do not offer this
review. Completed tasks must first be reopened through the existing explicit path.

The native review shows the imported title separately from the proposed current
one. Removing exactly one leading marker is optional. It defaults on only when
the current title exactly matches the imported content; edited wording is kept
by default and is never replaced with old source text. Cancel leaves the owning
editor untouched. Apply rechecks the complete captured editor draft, live editor
admission and heading availability before setting the known type and reviewed
title. Existing Save/recovery and undoable mutation paths retain persistence and
source/completion/generation checks. iOS applies to a draft requiring Save; Mac
uses its existing autosave path. Reviewed title words are literal, so dates,
priorities and project tokens cannot create unreviewed quick-entry edits.

Notes, nested tasks, files, comments, planning fields, recurrence settings, opaque
fields and the full source metadata remain intact. A heading stays open and does
not create recurring successors; ordinary descendants remain completable. This
review performs no provider requests, bulk conversion, source metadata rewriting
or automatic reinterpretation. Existing Todoist import retries still preserve
previous destinations and their edits.

Each repo passes 52 selected Core checks, including 7 new conversion cases.
Both app builds pass; the isolated Simulator app passes strict/deep signing checks.
One native scenario passes independently on iPhone and iPad: review Cancel, marker
choices, Apply then parent Cancel, separate Save, untouched-field preservation and
cold return. Both review images were inspected. Verification results are in
heading-conversion/. Core cases cover candidate
admission, exact content preservation, changed-source/capability refusal, edited
titles, marker choices, malformed/completed/type refusal and literal quick entry.
Native checks are scoped to synthetic local iPhone/iPad copies. Mac compilation
is distinct from native runtime acceptance; broader shared/cloud, spoken, large
text, cross-device and installed-widget acceptance remain open. This stage does
not close rank 3 or the wider Px goal, or change any user-deferred gates.
