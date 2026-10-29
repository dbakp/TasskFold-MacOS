# Native child field workflow acceptance

29 October 2026. The isolated child-field host exercises the actual Store factories,
Backend transport, gated editor, encrypted journal, presentation controller and
private unsent-editor files. The HTTP peer, credentials, accounts, encryption key
and refresh source are explicitly synthetic. Ordinary app flags remain absent/off;
no hosted SQL, real tasks, provider credentials or Keychain items changed.

## Product changes

- [x] Shorten the editor/recovery introductions so large text reaches the actual
  work sooner without removing the original-request and uncertain-result wording.
- [x] After a successful device checkpoint, dismiss the editor keyboard and request
  accessibility focus for the saved notice. Do this only for the same account and
  selected node, and only if no newer typing superseded the captured revision.
  Failed saves and newer typing keep their existing input state. The saved notice
  is scrolled fully into view before accessibility focus is requested. iOS waits for keyboard dismissal to settle the centered iPad sheet; delayed focus is bound to the original editor session, active scene and visible editor.
- [x] Preserve authored Unicode spellings in private draft revisions. Two new Mac
  regressions reproduced five failed assertions on the old model: a canonical-
  equivalent title or metadata update did not advance the draft, and an earlier
  checkpoint could retire it. The fixed model uses exact comparisons after a fast
  semantic check. Unchanged field callbacks no longer reopen a finished draft.
- [x] Use a standard alert for request removal. Cancel and destructive confirmation
  remain explicit across compact/popover presentations. The uncertain warning says
  removal cannot cancel or undo a server change.

## Native acceptance boundaries

Five cases are defined independently in each repo: device save/send and cold saved
receipt; lost reply and exact cold retry; account switch during response and return
of the original attempt; largest-text unsent typing and cold private-file recovery;
and uncertain-discard Cancel/confirm with server work preserved after relaunch.
Final accepted device phases and counts are recorded in verification.json and the
corresponding test summaries/logs. Do not count earlier partial/failed phases as a
complete run. Mac app/test compilation is distinct from Mac runtime acceptance.

The host uses two dedicated synthetic accounts and an exact bundle/launch-mode
allowlist. Its deterministic test key cannot be used by ordinary bundles or other
accounts. The real encrypted FileIO and Store paths are used; genuine Keychain
construction/access prompts and removal remain unaccepted. Confirmed refresh calls
Store.sync but this exact Debug mode refreshes from the local peer, not a hosted
provider. The peer is not an implementation of the complete PostgreSQL service;
existing 95-case SQL evidence remains separate and is not expanded here.

Each repository also passes 197 focused Core/controller/backup regressions (34 child-command/draft cases, 20 reads, 19 tree, 55 account transport and 69 backup cases). Full
isolated Mac and Simulator app/test builds and strict deep signatures are checked.
The new host preparation script refuses existing output folders; existing reserved
hosts were updated incrementally with their bundle/App Group namespaces retained.
Only their copies enable child read/write flags. Distribution/signing acceptance
for releases stays deferred.

## Test corrections and observed limits

Early runs exposed harness assumptions as well as product usability issues. The
peer initially used `missing` rather than the protocol's `absent` child-container
kind; the client correctly refused it. Selectable request text needed a label/value
query rather than a static-text-only query. At largest text, the system editing
menu paginates Select All; tests now use its actual Next Page button. The target
scroll helper is bidirectional and waits for the asynchronous read before moving.
Keyboard-modifier input was tried but did not select the iPhone text, so it is not
used as replacement proof. The final acceptance uses real selection and typing.

The original default diagnostic collector stayed alive after all three first-run
cases failed and the runner quit. Its output was preserved, then the owned
collector was explicitly cancelled before new tests. Later runs use Xcode's
supported `-collect-test-diagnostics never`; result summaries and kept screenshots
are still exported. This was not a restart caused solely by an observation timeout.

VoiceOver is temporarily disabled for pointer/typing automation and restored to
its prior Simulator state. These cases do not claim spoken announcements or
screen-reader navigation. Simulator accessibility-loader/launch diagnostics, if
present, are retained in the logs; a functional pass does not prove clean runtime.

## Still open before exposure

- [ ] Broader Mac native lifecycle/layout/speech and warning-free runtime. Direct v13 Save/send/cold receipt is observed; four v12 automated journeys failed.
- [ ] Genuine Keychain, full confirmed-account cleanup/retry, reboot/crash, shared
  team permissions, multiple windows/processes and real hosted refresh lifecycle.
- [ ] Spoken field/save/discard feedback, broader long values and remaining field
  controls/conflict review. The new form currently edits title, notes and priority.
- [ ] Completion/structure/heading/legacy adapters, authoritative child migration,
  history/quota policy, hosted compatibility and paired delivery.

Rank 6, the full child-data migration and Px remain unfinished. Existing user
deferrals for rollout, remote delivery, release/provider setup and real audio/
location testing remain in place.

## Final phases and desktop observation

The five mobile journeys pass per device in v10 (phone split 1 + 4). Visual review
then found the iPad normal-text notice below its sheet despite an overly broad
screen-bounds assertion. v11a fixes that; final v12 reruns the two affected
Save/send/cold and largest-text/private-cold cases per device, all four passing
with no reported runtime warnings. All four final saved-notice images were
inspected inside the actual sheet. The three other journeys retain v10 scope;
this is not five rerun journeys on the final binary.

After the second unlock, four Mac v12 XCTest journeys failed while discovering
or opening fixture/editor controls. Two negative-geometry runtime warnings
remain recorded. Direct native computer use exposed an identifier issue: macOS
propagated the Form identifier onto every child control. v13 limits that mobile
viewport marker to iOS, restoring the individual Mac identifiers; the iOS branch
is unchanged and both full test builds pass.

Direct Mac v13 computer use then edited a synthetic title, saved it on-device,
reviewed and explicitly sent it, quit and cold-launched. The queued state had
zero writes/requests; confirmation and cold return had one write/request and
the authored title, with a retained confirmed receipt and no Send action.
Screenshots are kept here. This narrow observed flow does not turn the failed
automated suite green, establish warning-free runtime, or accept retry/account/
window/Keychain/speech lifecycle. Test sessions were closed afterward.
