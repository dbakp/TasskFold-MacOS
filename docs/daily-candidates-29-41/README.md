# Daily-use candidates 29 / 41 — 6 November 2026

Mac **1.2.0 (29)** and iPhone **1.4.0 (41)** are built from the recorded merged
source snapshots, using optimized Release code and existing development profiles.
Each owner independently builds and archives its app. No sibling repo is used as
a build input. The ordinary project and release entitlements stay untouched.

The Mac package includes app, widgets and Share. The phone package includes app
and widgets; its existing development-only incoming Share omission remains.
The ordinary feature flags exactly match the previous candidates. Advanced
rollout safeguards and hosted services are unchanged. On-device assistance has
no cloud fallback; these builds do not establish model readiness or generation
quality. Mac screen interactions, physical FPS, broader native/speech/provider
acceptance and the three paused rollout items retain their earlier limits.

## Frozen package verification

The build receipt binds the current app inputs and build tools. Packaging checks
the owning identity/version, source fingerprint, baseline ZIP hash and strict
signature. It extracts the new archive into an isolated temporary directory,
compares every file, symlink and permission, and verifies signatures, embedded
profiles and app/extension metadata again. Publication is exclusive and cannot
replace an existing package. The main app's actual compiler invocation uses
`-O`, with no `-Onone`. `package.json`, `build.json` and `verification.json` record
this scope; passing packaging is not physical installation or App Store acceptance.

The profiles are unchanged and expire **10 November (Mac)** and **11 November
(phone)**. These personal development packages require renewed profiles for use
after expiry. Existing-profile signing does not extend their dates. The Mac
candidate targets this host architecture; general Mac distribution stays deferred.

## Current installation boundary

At packaging time, Mac23 remained installed and running with the same binary payload. This historical boundary is now superseded by the Mac29 installation receipt below; future routine Mac updates no longer require a saved-draft question. Phone34 is the last
verified installed version; phone41 installation stays explicitly deferred even
though a paired phone is visible. Neither packaging command installs, launches,
quits an app, reads task rows or exports private keys. No new native normal-app
workflow/real-account test is claimed here.

The user-facing START HERE notes now identify the real current candidate instead
of earlier 27/39. Superseded uninstalled 28/40 archives were retired after
new 29/41 readback passed; installed 23/phone34 and the accepted Mac14 rollback are
retained while the new Mac installation remains pending. Tiny historical receipts
remain provenance records, rather than active installation instructions.

## Reproduce independently

From each owning repo, use `Scripts/build_daily.py --cached-profiles
--build-number BUILD`, then `Scripts/package_daily.py --receipt BUILD_RECEIPT
--output OUTPUT_DIRECTORY --baseline-receipt BASELINE_RECEIPT`. For the phone,
also use its already registered `--device`, `--offline-device` and documented
`--without-share` variant. This does not configure an account, renew profiles,
reset quota or install on a device. Installer preparation/approval remains separate.

## Subsequent installation on 6 November

Mac29 is now installed over23 with a private safety copy, exact archive/signature verification and five task/pending caches preserved before launch. The user cleared the macOS app-data prompt; its normal main window and synced state are verified, with all five task/pending caches still exact. See [installation status](../mac29-installation/README.md). The user has authorized future routine Mac updates without draft confirmation. Phone41 remains deferred. These package receipts remain frozen preparation evidence.
