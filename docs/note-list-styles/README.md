# Clean note list styling · 6 November 2026

Switching a selected note between bullets and numbers now replaces its existing list marker: `- Review` → `1. Review` → `- Review`, instead of `1. - Review`. Clicking the active list style again returns the selected items to plain text. Mixed plain/list selections become one consistent list without stacking recognized markers. Numbering restarts at 1 within the selection, as before; indentation is preserved.

Marker recognition follows the current reader: `-`, `*` and `+` bullets and one through nine ASCII digits followed by a period or closing parenthesis and a space. Longer digit runs, non-ASCII numerals and marker-like ordinary text remain literal. Only one structural marker is replaced; intentional nested literal text is retained. Quote toggling preserves its entire list contents.

Shared line decomposition keeps each original LF, CRLF, CR, Unicode line separator or paragraph separator unchanged, along with blank indentation and adjacent UTF-8. Empty selections retain a selected placeholder for typing. The formatter refuses invalid UTF-16/grapheme selections and outputs beyond its existing 512,000-byte budget. Heading styles reuse the same line decomposition and pass their existing regressions. There are no new controls or changes to text-only Save, recovery, account admission, task identity, completion, pin, scheduling or service contracts.

Two focused baseline cases reproduce five failed assertions in the prior iOS implementation. Both owners then pass 48 focused Core checks, including 11 new list cases, existing inline formatting, heading levels, safe preview and source-binding regressions. Tests cover actual rendered model list bodies, mixed styles, selection boundaries, preserved original bytes, every supported line terminator, blanks, marker grammar and size/selection refusal. This verifies the transformation called by the existing native buttons; it does not claim new gesture/keyboard/speech, physical smoothness or wider account acceptance. No real task data is modified for testing.

Current installed Mac23 remains running; installed iPhone34 remains untouched and further phone installation stays deferred. Build/package results are recorded separately when complete. Existing provider, remote-reminder, older-client and distribution deferrals remain, as do ordinary advanced gates. Each repository owns its implementation and tests independently.

## Prepared daily update

Mac 1.2.0 (24), including app, widgets and incoming Share extension, is signed and archived; installed Mac23 is unchanged. Exact archive readback, strict signature, embedded cached development profiles and owning metadata checks pass. The package is prepared, not installed or distribution-accepted. Cached signing does not renew the profile: earliest expiry 2026-11-10T18:32:04+00:00. No new isolated native interaction or physical smoothness acceptance is claimed.
