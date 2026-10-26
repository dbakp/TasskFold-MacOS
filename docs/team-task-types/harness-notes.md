# Initial failures and corrections

The first Core run exposed an actual missing-baseline check: completed_at missing
was treated like explicit null. Typed root validation now requires the field.
Initial database assertions expected a permission error for an outsider; the
existing non-disclosing PT404 is the correct response. The descendant preservation
fixture initially omitted the completion metadata that the existing server lazily
adds. The final fixture supplies complete metadata and verifies exact descendant
preservation. The direct-write refusal query initially returned SQL null on a
zero-row RLS update, which the JSON-only fixture cannot decode; it now returns an
explicit changed-row count or error object and checks that neither changes data.
No service refusal was weakened to satisfy these harness corrections. Both final
owned database runs pass and clean up their containers. Native tests were not run.
