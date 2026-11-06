# Reviewed task output and exact source ownership

PDF Save and CSV Save/Share now use the same live byte-release rule: the reviewed
options, source, workspace incarnation and presentation must still be current.
Each Save has its own immutable item and callback identity. Cancelling, closing,
changing options or losing the source invalidates that permit and clears its bytes;
a later request cannot revive it. A previous callback cannot settle another Save.
Data already released to a provider remains outside app revocation. This is not a
claim that external copies can be erased or a completed transfer can be recalled.

The native Save dialog uses SwiftUI's Transferable exporter. Its presenter spans
the review instead of using a zero-size anchor. The iOS native PDF view receives an accessibility-suppression flag while a modal
covers it. XCTest still includes covered nodes in its snapshots, so a zero-node
proxy was rejected and spoken acceptance remains open. Existing Save/Share labels and explicit review choices remain.

## Exact authored text and cached rows

The preceding output comparison accepted canonically equivalent String edits.
The preceding task cache also retained the older title/notes for that edit. Two
frozen regressions reproduce seven source-field assertion failures and three cache
assertion failures in each repo's original models. These are two test cases, not
ten distinct cases. Before logs and frozen regression source are retained here.

PrintDocument now compares exact UTF-8 text, including groups, context, CSV metadata
and raw source fields. Pinned-note output checks its whole captured record by the
same rule. TaskCache invalidates for authored byte changes, including opaque values,
while unchanged rows keep their existing cached results. Shared array-buffer identity
is a fast path. Object insertion order stays irrelevant; dictionary key bytes and
numeric bits are exact. The iterative JSON comparison avoids adding recursive
stack depth. Domain Record/JSON equality and saved-file formats are unchanged.

## Verification

The current focused runs execute 107 selected Core cases on Mac: 105 pass and two
existing disposable native ordering/account fixtures are skipped because their
inputs were not supplied. iOS executes 106, all passing. Fourteen new cases cover
actual PDF/CSV CoreTransferable representations, live context/options changes,
closed presentation/repeated/delayed/cancelled requests, real local file export,
exact text/context/opaque data and visible cache invalidation without unnecessary
recomputation. No network provider, microphone or speech permission is used.

Final native acceptance passes four selected cases on ARM64 Mac and five each on
iPhone/iPad Simulator, with zero failures/skips/reported runtime warnings. The
cases cover actual local PDF/CSV Save/readback, repeated Save/Cancel, native source
and workspace-incarnation revocation, unchanged saved tables and cold return;
mobile also covers Share-sheet cancellation and option exclusions. Final source/
binary hashes, strict summaries and inspected captures are adjacent. The full CSV
is byte-identical across all three platforms; independent Python parsing verifies
19 columns, four full/three reduced rows, heading and file-local parent references.
The actual PDF readbacks retain both pages and final instructions. Renderer styling
was not changed, and no new PDF raster-layout acceptance is claimed. Initial failures are retained separately: the Mac sandbox refuses
cross-container fixture writes; iOS picker starts/filenames are not assumed to be
the app's Documents directory, and the actual Save success URL is recorded only in
the reserved debug fixture for readback. No permissions were relaxed.

The Mac race fixture uses a fresh, dictionary-free distributed-notification name
to signal its own isolated app after XCTest observes the Save panel. No production
observer exists. Both clients require DEBUG, the exact reserved bundle, ui-testing
owner and workflow flags before any fixture mutation. The source race changes
Résumé to a canonically equal Unicode spelling; the workspace race rotates the
real Store incarnation. Saved task tables must survive unchanged after cold return.
This tests a local source/incarnation transition, not a real signed-in account picker.

## Remaining scope

Real external file-provider/cloud delivery, authenticated account-picker and wider
multi-window races, pinned-note native source changes, spoken/largest-text output
acceptance and hardware printing remain separate requirements. Broader Mac runtime
warning work is not closed by functional output tests. User-deferred release,
older-client rollout, remote reminders, provider setup and real audio remain deferred.
The full Px goal stays active.

## API references

[Apple: exporting a Transferable item](https://developer.apple.com/documentation/swiftui/view/fileexporter%28ispresented%3Aitem%3Acontenttypes%3Adefaultfilename%3Aoncompletion%3Aoncancellation%3A%29)
and [Apple: sandboxed distributed notifications without a dictionary](https://developer.apple.com/documentation/foundation/distributednotificationcenter/postnotificationname%28_%3Aobject%3Auserinfo%3Adeliverimmediately%3A%29).
