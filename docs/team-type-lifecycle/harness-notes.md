# Harness corrections

The first conversation assertion looked for the old comment ID/revision. Existing
certified recovery deliberately creates a fresh ID and revision 1 while preserving
content, authorship and original creation time. The corrected test checks those
properties and the new task incarnation. The JSON-only fixture initially received
no row when querying the old ID; no production recovery code was changed for this.
The untyped-receipt assertion initially passed undefined to a helper whose default
expected value is true; it now explicitly checks that the field is absent.
Both final service runs pass 100 checks and remove their owned containers.
No native or hosted runtime acceptance was run in this stage.
