# Reviewed conversion of older Todoist headings

Updated 27 October 2026. Both independently owned apps offer **Review imported heading**
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

Initial 26 October verification: each repo passed 52 selected Core checks, including 7 new conversion cases.
Both app builds pass; the isolated Simulator app passes strict/deep signing checks.
One native scenario passes independently on iPhone and iPad: review Cancel, marker
choices, Apply then parent Cancel, separate Save, untouched-field preservation and
cold return. Both review images were inspected. Verification results are in
heading-conversion/. Core cases cover candidate
admission, exact content preservation, changed-source/capability refusal, edited
titles, marker choices, malformed/completed/type refusal and literal quick entry.
The 26 October checks above were scoped to synthetic local iPhone/iPad copies.
The 27 October follow-up below adds current Mac interaction and mobile largest-text
acceptance. Broader shared/cloud, spoken, cross-device and installed-widget cases
remain open; normal authoring and all user deferrals stay unchanged.

## 27 October — exact imported-heading review and native completion

The old conversion guard used semantic Record equality. Swift considers NFC/NFD
strings equal, so a review could accept a draft whose title or other raw metadata
had changed, then use its older captured title. The old marker default also treated
an equivalently spelled edited title as identical to its imported source. Both
owned implementations now compare raw UTF-8 strings and object keys, ordered arrays,
JSON kinds and numeric bits before Apply. Iterative traversal keeps complete future
metadata without adding a depth quota or serializing the record on every check.
Object field order is irrelevant. The iOS editor, Mac inspector and review's final
Apply all use this check; unavailable/changed drafts retain the existing refusal.
The current title, rather than an imported source title, remains the only proposed
wording. A raw spelling change counts as edited for the marker default and its
existing explanation. Normal source mapping, import retries and provider behavior
are unchanged; no Todoist request is made by this workflow.

Two new Core cases fail against each old model: nine reported cases, two failed
cases with six failing assertions, seven passing cases. After the correction, 62
selected checks per repo pass without failures/skips. They cover conversion,
task-kind rules, checklist organization and personal compatibility. New coverage
includes canonically equal title/notes/unknown-value/key changes, signed zero,
dictionary reordering and 256-level opaque metadata. These are focused runs, not
new full-suite, hosted or performance acceptance.

Two current native cases pass on each platform. Mac verifies review Cancel,
explicit marker choices, autosave, exact other-field preservation, completion
revision 0 → 1 → 2 → 3 across conversion/Undo/Redo, ordinary child completion/Undo
beneath the still-open heading, and normal Quit/relaunch with saved-table equality.
Its separate long edited-title case keeps the current wording and marker, reviews
both marker choices and retains the result after normal Quit/relaunch. Phone and
tablet verify review Cancel, draft Apply versus parent Cancel, explicit Save and
cold return; their largest-text dark case preserves long edited wording, activates
a fully visible physical switch in both directions, saves the conversion, completes
an ordinary child through parent Save and checks the entire saved task and cold
workspace. Literal tomorrow/#work/p1 words do not change dates, labels or priority.
Only synthetic local copies are used. No genuine Todoist, cloud/shared, spoken,
installed-widget, distribution or every-device acceptance is inferred.

Representative retained screenshots were visually inspected. Mac long titles wrap without losing
the review content, and the controls remain clear. The first largest-text iPhone
capture showed the inline title as Review…; the iOS-only adaptive title is now
Review at accessibility sizes while normal-size mobile and Mac retain Review heading.
Both actions keep their complete labels and the body retains Imported heading.
Text size is not reduced. The final mobile runs use this polish, including an
assertion for the actual Review navigation title.

Two XCTest Mac priority warnings remain, so its strict verifier still rejects
clean runtime acceptance. Four live events within the final run match the exact
isolated host path and timestamps across its launches; all have UUID-matched
system frames through _getDataDetectorsScanner, Services menu updates and NSMenu
accessibility inspection. These event and issue counts are not assumed identical.
Missing frames remain unresolved. This establishes the observed menu-inspection
trigger without suppressing Services, changing system permissions, treating the
warnings as harmless or claiming all pauses have that cause.

Initial native failures are retained separately. Mac's generic toggle wrapper had
no numeric accessibility value; its default title plus actual on/off title changes
now verify the behavior rather than assuming that wrapper API. The first iPhone
largest-text driver stopped when only the switch label was entering the viewport;
its recorded tap missed the switch. The corrected driver requires the complete
control within the form's visible frame, then verifies actual switch states and
title changes. A later iPad run overscrolled the first child row and kept scrolling at the
bottom; its exact hierarchy and frame are retained. That test now uses smaller,
slow bidirectional gutter drags on iPad and verifies the complete checkbox frame.
Phone keeps its original tested path. Its recorded application sources and both
app binaries are identical after this iPad-only runner change, with the original
phone runner/source binding retained separately. The pre-title mobile runs also
pass, but accepted mobile behavior uses the post-polish application source.
These were driver refinements, not speculative layout fixes.
No source work, hosted schema, production opt-in, provider configuration, release
setting or user-deferred item changes. Wider shared/cloud/source-race, spoken,
cross-device, installed-widget and full Px work remain open.
