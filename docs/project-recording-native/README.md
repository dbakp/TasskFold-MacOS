# Recording choices in native project review

Reviewed 3 November 2026. The whole-project transfer feature is still disabled and unfinished. This checkpoint concerns native consent and saved-request presentation, with a synthetic native peer; it does not establish integrated SQL/gateway/Storage acceptance.

## Product changes

Both apps now put personal access choices first, then connection and recording consents, followed by Review. Changing access still clears recording approval. The ordering avoids asking people to approve an audience before finishing its access choices, then sending them back up the form to approve again.

Published and unfinished counts have explicit accessible labels and values in final review, saved retry and the confirmed result. Review keeps published movement separate from stopping unfinished sends. Existing task data, exact-request semantics, service policy and normal-use gates are unchanged.

## Native verification

The owning iPhone accepts two native cases, with no failures or skips, at Accessibility XXXL in light appearance with Increase Contrast off. It verifies the reviewed 1 published/2 unfinished counts, consent resets/cancellation, a deliberately lost applied reply, cold saved-count presentation, exact original retry, final count2 and the refreshed destination boundary with no queued edits. The normal Keychain-backed request vault is used in the isolated signed Simulator app; this is not a hardware/Keychain/encryption audit. Both independently owned app/test-runner builds and strict signatures pass. Source/build identities and raw counterpart reports are recorded in verification.json.

Native checks are split so later recovery work does not repeat every consent-state check:

- Consent: neither/partial/both choices, removing the unfinished-send choice, clearing both after an access change, and cancelling without a command or task-table changes.
- Retry: both reviewed counts, Back clearing consent without a command, separate renewed choices, a deliberately lost applied reply, cold saved-request presentation and the exact original retry.

The native peer adapts only recording capability/count/policy fields from this repository's captured SQL contract onto the existing synthetic workspace. Every request is intercepted. It validates the selected policy and both counts, but its signatures, account and project responses remain synthetic. Native acceptance here must be composed with the separately recorded [151 local service checks and 83 client tests](../project-unfinished-recordings/README.md); it is not an integrated native service test. Those unchanged service/Core suites are not rerun for a view-order/accessibility change.

The iOS repository owns the native runner and cases. Mac owns its UI, preparation code and build inputs independently. Copied counterpart audit reports do not create a build dependency or establish Mac runtime acceptance.

## Attempt qualifications

Failed exploratory runs do not count as acceptance. The largest-text form exposed navigation helpers that omitted the last gesture's result check, assumed a fixed swipe budget and searched down at the end for a lazy row above the viewport. They now check the final result, use heading geometry and detect the actual scroll end before searching upward. A later run reached final review but the selected count element had an empty accessibility value; recording readouts now expose explicit labels/values. A row-relative coordinate tap also missed the small nested switch; tests now tap its actual control. A later case reached cold success but had not scrolled to the refresh footer; final count/status rows are now revealed and the destination cache is checked independently. See failed-attempts.json. Concise reports and failure screenshots were retained before deleting only obsolete failed result bundles.

## Remaining

- [ ] Separate native Mac/iPad consent, cancellation and cold-retry acceptance.
- [ ] Wider lifecycle/account/window/privacy, audible VoiceOver and display-mode acceptance; an accessibility-tree check is not spoken-output verification.
- [ ] Pending-only native presentation, combined connection/unfinished contexts, retained/legacy/other mixed media policies, other realm directions and genuine integration before ordinary use.

All previous user deferrals remain. No hosted service or release configuration changed.

## Mac recheck

The owning preparation CLI supports `--recordings`; `--reuse-host` additionally requires a verified reserved team-editor receipt. Run the storage guard before building/testing, and reuse current products. No Mac native case is accepted by this checkpoint, and the iOS runner is not a Mac build input.

```sh
python3 Scripts/check_test_storage.py --path /tmp
python3 Scripts/prepare_project_adoption_native_test.py --help
```

The app and test-runner build/signature identities are recorded in verification.json. Native Mac/iPad acceptance remains explicitly open above.
