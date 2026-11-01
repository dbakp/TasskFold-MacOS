# Preserve unfamiliar data in legacy checklist transforms

Editing a normal row previously rebuilt every sibling through `JSON.object`, which could turn a preserved object or text/number row into an empty object. The field-change helper now keeps every non-object sibling unchanged and retains an unsupported non-array container unchanged. Known ordinary rows still receive the requested field changes.

Indenting under a preserved object or an ordinary parent with an unsupported child container could likewise replace original content while creating the new child array. Indent now requires an ordinary named parent and a null/array child container before making any change. Refusal keeps the full original tree intact. These are guards around legacy transforms; preserved objects continue to use the independent editing path. The user-facing indexed refusal now asks for review without implementation terminology.

Each repository passes 219 focused checks, including two added regressions for mixed preserved/text/number siblings and unsupported indent parents, plus existing hierarchy, transfer, activity, widget and list-completion checks. Current app/runner builds and signatures are recorded separately in `verification.json`. The guards have core/build evidence, not new native interaction acceptance.

The existing-history iPad workflow remains accepted at the earlier indexed-child-routing milestone with its exact source/build provenance. These later helpers do not change that workflow's native controls; no repeat or wider native claim is inferred. Other legacy transformations and the larger cache/editor migration still require integration and acceptance. No hosted schema, normal-use gate, real data or user deferral changed.
