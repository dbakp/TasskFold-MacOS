# Fresh subtask reads preserve unfamiliar metadata

Both wire versions now admit distinct UTF-8 keys inside nested field values while retaining strict envelope, node and field-member validation. Exact duplicate decoded keys remain refused everywhere. Identities, existing counter checks (including the V2 literal grammar), hierarchy/order, byte limits, depth limits and captured-context checks remain intact. The preserving codec retains unknown objects/numbers; field requests send only the supported edited fields, and structural moves send identities/revisions rather than resubmitting existing metadata.

Authored-content comparison now understands harmless JSON whitespace, object key order, escape spelling and exact decimal notation inside preserved values. Keys and strings compare their decoded UTF-8 bytes; numbers compare exact normalized decimal tokens without Double conversion. Array order and canonical-distinct string/key spellings remain significant. Unaddressable exponents retain conservative lexical comparison. Raw storage/export equality and output bytes are unchanged; the comparison representation is never stored or transmitted.

The synthetic native fixture now carries the exact numeric/Unicode metadata inside the child itself, in addition to the existing root metadata and large number. Its probe checks the cached and peer copies after save/send/cold return.

## Scope and remaining work

This removes the fresh-read metadata refusal; it does not complete older-subtask migration. Whole ambiguous node/field containers still refuse safely. Main-list editing/routing, indexed/history mapping, shared attachment/discussion custody and wider account/protected-storage/window/background/concurrency/spoken/library acceptance remain open. Ordinary child gates remain off. No hosted schema/data changes or release acceptance are claimed. User deferrals remain unchanged.

The previous phase's full regression and native results remain historical evidence in ../preserving-json/. This phase uses relevant subtask/codec/hierarchy checks and explicitly scoped native evidence; it does not claim a newly repeated full-product regression.

## Recorded results

Each repository independently passes 496 relevant Core cases, with one explicit live-integration skip and zero failures. Seven new cases cover both wire versions, exact data retention, field-only requests, harmless formatting, real content changes, duplicate/structural keys, counters/depth and structural payload restrictions. The Mac seven-case final control retake overlaps its broader run and is not added to its distinct-case count.

Both app/test products build and pass strict development signatures. Mac direct computer use and iPhone/iPad XCTest each verify the synthetic save/send/cold-return path. Saved-file inspection independently confirms child metadata numbers and both raw Unicode key spellings, with one request/write. Test apps are closed afterward. No real account/Keychain or hosted-service acceptance is implied.
