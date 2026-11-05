# Note section navigation and lazy reading · 5 November 2026

Both repos independently implement a persistent Jump to section control in the pinned-note reader and formatting preview. Formatted blocks now use LazyVStack instead of laying out every block at opening. Heading titles reuse the background-prepared inline render model; duplicate names keep distinct destinations, empty headings are excluded, and original-only fallback has no inexact targets. Viewing original text hides section navigation. No note representation, saved task data, print output, permissions or ordinary feature gate changes.

Normal text uses the native compact menu. Accessibility text uses a full-height native section list, with Close and multiline titles; selection scrolls only after that sheet dismisses. Content anchors have a separate namespace from heading-choice identities. Changed-source guards prevent a retained choice from navigating a revised render model.

## Current verification

- 34 focused Core checks pass independently in each repo, including four new heading cases. Current iPhone app/test and Mac app builds succeed; development signatures verify.
- A pre-follow-up normal iPhone journey passed reader and editor-preview first/last section navigation, exact original toggle, unchanged tables and cold return. The 12-section synthetic guide initially reported 25 appearing blocks. `pre-followup-normal-iphone.json` preserves its exact earlier source/binary binding; it is reference evidence, not acceptance of the subsequent routing changes.
- Initial test failures selected the underlying sheet's toolbar, queried a propagated child identifier as a container, or tapped the toggle label rather than its switch. Those selectors were corrected. The first largest-text attempt needed the system menu's virtualized list scrolled before querying a distant choice.
- A later largest-text run selected the last section but did not verify the selected heading as visible; its recording still showed the first section. Minute-long UI waits coincided with the locked Mac, confirmed by computer control. The exact root cause is not claimed proven. The follow-up removes ambiguous content/choice targets and uses an accessibility-sized list with routing after dismissal.

**Current native normal/largest-text rechecks are pending until the Mac is unlocked.** No completed broad checkpoint, FPS claim, physical-device acceptance, Mac/iPad interactive acceptance or VoiceOver claim follows from the builds/Core results. The previous normal reference and two largest-text failures are deliberately retained separately.

## Daily updates and storage

Normal apps remain Mac14/phone31. Verified frozen Mac22/phone34 ZIP archives remain intact. The attempted Mac23 build was cancelled when the largest-text issue was identified; it was not packaged or installed. The cached app still declared version22 but its payload no longer matched the frozen archive after the interrupted attempt, so that generated cache product was retired. No completed Mac23 package exists. The verified frozen Mac22 archive remains intact and is the installation source for the existing update window.

Current-source runtime acceptance comes before packaging the new notes update. Test result bundles and duplicate exported recordings are pruned only after retaining concise result summaries, hashes, the reference screenshot and the before-fix selection frame. No real tasks, device/app data, Keychain items, Docker volumes or unrelated test output are removed.
